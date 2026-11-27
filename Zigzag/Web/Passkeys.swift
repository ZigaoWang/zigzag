import AuthenticationServices
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

    /// No passkeys: always for AI apps, else without the entitlement unless a password manager has them.
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
    ///
    /// A passkey picked in Zigzag's fill menu (`PasskeySuggestions`) ends the waiting request and asks for that one
    /// passkey with the site's own options; its answer is the waiting request's. Cancelled, the request waits again.
    static let requests = WKUserScript(source: """
    \(requestsMarker)
    (() => {
      const KEY = Symbol.for('zigzag.passkeys');
      if (window[KEY]) return;
      // This frame's waiting request, and its passkey sheets (a sheet asked for twice is still one on screen).
      let waiting = null;
      const sheets = new Set();
      // What the waiting request asks for, and how to sign in with one passkey in its place (`choose`).
      let offer = null;
      const end = () => {
        const controller = waiting;
        if (!controller) return false;
        waiting = null;
        offer = null;
        controller.abort();
        return true;
      };
      // Page globals captured before its scripts run, so redefinitions aren't called.
      const encode = window.btoa, decode = window.atob, fromCode = String.fromCharCode, Bytes = Uint8Array, Buffer = ArrayBuffer;
      const base64url = (source) => {
        try {
          const bytes = source instanceof Buffer ? new Bytes(source) : new Bytes(source.buffer, source.byteOffset, source.byteLength);
          let text = '';
          for (const byte of bytes) text += fromCode(byte);
          return encode(text).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
        } catch (_) { return null; }
      };
      // For Zigzag's fill menu: the site the waiting request is for, and the passkeys it allows (none: any).
      const offered = () => {
        if (!offer) return null;
        try {
          const key = offer.options.publicKey;
          const rpId = typeof key.rpId === 'string' ? key.rpId : null;
          const allow = [...(key.allowCredentials || [])].map((credential) => base64url(credential.id)).filter((id) => id);
          return { rpId, allow };
        } catch (_) { return null; }
      };
      // The passkey picked in Zigzag's menu: the waiting request makes way for a request for that one alone, which
      // answers the site's waiting one.
      const choose = (id) => {
        const current = offer;
        if (!current || typeof id !== 'string') return false;
        const allowed = offered();
        if (!allowed || (allowed.allow.length && !allowed.allow.includes(id))) return false;
        let bytes;
        try {
          const text = decode(id.replace(/-/g, '+').replace(/_/g, '/'));
          bytes = new Bytes(text.length);
          for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
        } catch (_) { return false; }
        current.pick(bytes);
        return true;
      };
      // In every frame, before anything can return: a frame without passkeys still answers, and can't bring its own.
      try { Object.defineProperty(window, KEY, { value: Object.freeze({ end, offered, choose }) }); } catch (_) { return; }
      const Container = window.CredentialsContainer;
      if (!Container || !Container.prototype) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
      const post = handler && handler.postMessage.bind(handler);
      const Controller = window.AbortController, Signal = window.AbortSignal, Waiting = Promise, assign = Object.assign;
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
        const rest = args.slice(1);
        return new Waiting((resolve, reject) => {
          const ask = () => {
            const controller = new Controller();
            const signal = site ? any([site, controller.signal]) : controller.signal;
            // The site's own options, read by WebKit as they are, with the one signal in place of the site's.
            const forwarded = new Proxy(options, {
              get: (object, key) => (key === 'signal' ? signal : key === 'mediation' ? 'conditional' : read(object, key, object)),
            });
            let picked = false;
            const entry = { options };
            const closed = () => {
              if (waiting === controller) waiting = null;
              if (offer === entry) offer = null;
            };
            // A sheet for the one passkey, with the site's options and signal. Cancelled, the request waits again.
            entry.pick = (id) => {
              picked = true;
              closed();
              controller.abort();
              let one;
              try {
                const publicKey = assign({}, options.publicKey, { allowCredentials: [{ type: 'public-key', id }] });
                one = assign({}, options, { publicKey });
                delete one.mediation;
                delete one.signal;
                if (site) one.signal = site;
              } catch (error) { reject(error); return; }
              const sheet = begin(name, target, self, [one, ...rest]);
              const again = (error) => {
                if ((site && site.aborted) || waiting) { reject(error); return; }
                if (sheets.size) { apply(then, settled([...sheets]), [ask, ask]); return; }
                ask();
              };
              apply(then, sheet, [resolve, again]);
            };
            waiting = controller;
            offer = entry;
            let request;
            try {
              request = apply(target, self, [forwarded, ...rest]);
            } catch (error) {
              closed();
              reject(error);
              return;
            }
            apply(then, request, [(value) => { closed(); if (!picked) resolve(value); }, (error) => { closed(); if (!picked) reject(error); }]);
          };
          ask();
        });
      };

      // A passkey request, once the waiting requests of the page's other frames are ended.
      const begin = (name, target, self, args) => {
        const go = () => start(name, target, self, args);
        if (!post || alone()) return go();
        let asked;
        try { asked = post(null); } catch (_) { return go(); }
        return apply(then, asked, [go, go]);
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
            return begin(name, target, self, args);
          },
        });
        Object.defineProperty(Container.prototype, name, described);
      }
      window.addEventListener('pagehide', end, true);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
}

// MARK: - Suggesting saved passkeys

/// Whether macOS lets Zigzag see the passkeys saved on this Mac (System Settings › Privacy & Security › Access web
/// browser passkeys). Asking is what puts Zigzag in that list.
nonisolated enum PasskeyAccess: Equatable, Sendable {
    case allowed, denied, notAsked
}

/// A passkey saved on this Mac, in the Passwords app or a password manager app, as macOS lists it to a browser.
nonisolated struct SavedPasskey: Equatable, Sendable {
    let name: String
    let relyingParty: String
    let credentialID: Data

    /// Base64url, as the page script writes credential IDs.
    var id: String {
        credentialID.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The Mac's side, behind a protocol so tests can stand in for it: the real one needs the entitlement.
protocol SystemPasskeys: AnyObject {
    var access: PasskeyAccess { get }
    func requestAccess() async -> PasskeyAccess
    func passkeys(for relyingParty: String) async -> [SavedPasskey]
}

/// Apple's web browser passkey access (`ASAuthorizationWebBrowserPublicKeyCredentialManager`).
final class MacPasskeys: SystemPasskeys {
    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()

    var access: PasskeyAccess { Self.access(manager.authorizationStateForPlatformCredentials) }

    func requestAccess() async -> PasskeyAccess { Self.access(await manager.requestAuthorizationForPublicKeyCredentials()) }

    func passkeys(for relyingParty: String) async -> [SavedPasskey] {
        await manager.platformCredentials(forRelyingParty: relyingParty).map {
            SavedPasskey(name: $0.name, relyingParty: $0.relyingParty, credentialID: $0.credentialID)
        }
    }

    private static func access(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> PasskeyAccess {
        switch state {
        case .authorized: .allowed
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .denied
        }
    }
}

/// Saved passkeys in Zigzag's fill menu, where a page waits for one (WebAuthn's conditional mediation), as Safari
/// lists them under a sign-in field. macOS is asked for access only when you pick Use a Saved Passkey there or
/// Allow in Settings › Passwords, never by itself. Denied or never asked, passkeys work as before: a site that asks
/// for one gets the Mac's own sheet.
final class PasskeySuggestions {
    static let shared = PasskeySuggestions(system: Passkeys.available ? MacPasskeys() : nil)
    /// Access was asked for and answered.
    static let changed = Signal<Void>()

    private let system: SystemPasskeys?

    init(system: SystemPasskeys?) { self.system = system }

    /// Without the entitlement there's nothing to ask for, and nothing is suggested.
    var isAvailable: Bool { system != nil }

    var access: PasskeyAccess { system?.access ?? .denied }

    func requestAccess() async -> PasskeyAccess {
        guard let system else { return .denied }
        let answer = await system.requestAccess()
        Self.changed.send()
        return answer
    }

    /// What the page's waiting request asks for: its site (the page's own when it names none) and the passkeys it
    /// allows, none meaning any.
    nonisolated struct Offer: Equatable, Sendable {
        let relyingParty: String
        let allow: [String]
    }

    /// The page script's answer (`offered()`), for a page on `host`. A site the page may not ask for is no offer.
    nonisolated static func offer(from value: Any?, host: String) -> Offer? {
        guard let body = value as? [String: Any] else { return nil }
        let host = host.lowercased()
        let relyingParty = (body["rpId"] as? String)?.lowercased() ?? host
        guard fits(relyingParty, on: host) else { return nil }
        return Offer(relyingParty: relyingParty, allow: body["allow"] as? [String] ?? [])
    }

    /// A page may ask for its own host's passkeys or a parent domain's, never a public suffix's or another site's.
    nonisolated static func fits(_ relyingParty: String, on host: String) -> Bool {
        guard !relyingParty.isEmpty, !host.isEmpty else { return false }
        if relyingParty == host { return true }
        return host.hasSuffix("." + relyingParty) && PublicSuffix.registrableDomain(relyingParty) != nil
    }

    /// Where the menu may list passkeys: a copy with the entitlement, a profile given your data, the page's own
    /// field (not a frame's) marked for passkeys (autocomplete "webauthn") and not for a new password, on a secure
    /// page, with no password manager extension that brings its own passkeys.
    nonisolated static func mayOffer(available: Bool, getsYourData: Bool, managerOn: Bool, isMainFrame: Bool, passkeyField: Bool,
                                     newPassword: Bool, scheme: String, host: String) -> Bool {
        available && getsYourData && !managerOn && isMainFrame && passkeyField && !newPassword
            && (scheme == "https" || host == "localhost")
    }

    /// A password manager extension that brings its own passkeys is on in the profile. iCloud Passwords' doesn't.
    static func managerOn(in profile: Profile) -> Bool {
        guard let manager = PasswordManagers.active(in: profile) else { return false }
        return manager != PasswordManagers.known[PasswordFiller.iCloudExtensionID]
    }

    /// The rows for an offer: the passkeys saved for its site that it allows, by name; Use a Saved Passkey until
    /// macOS has been asked; nothing once it said no.
    func items(for offer: Offer) async -> [AutofillMenu.Item] {
        guard let system else { return [] }
        switch system.access {
        case .denied: return []
        case .notAsked: return [.allowPasskeys]
        case .allowed: return Self.listed(await system.passkeys(for: offer.relyingParty), for: offer).map { .passkey($0) }
        }
    }

    nonisolated static func listed(_ saved: [SavedPasskey], for offer: Offer) -> [SavedPasskey] {
        saved.filter { $0.relyingParty.lowercased() == offer.relyingParty && (offer.allow.isEmpty || offer.allow.contains($0.id)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The page's waiting request, asked without a user gesture, in the page's world where the request is.
    func offer(in webView: WKWebView, origin: Origin) async -> Offer? {
        let value = try? await webView.runOwnScript("window[Symbol.for('zigzag.passkeys')]?.offered?.() ?? null", world: .page)
        return Self.offer(from: value, host: origin.host)
    }

    /// The rows for the page's focused field, if the page waits for a passkey.
    func items(in webView: WKWebView, origin: Origin) async -> [AutofillMenu.Item] {
        guard isAvailable, access != .denied, let offer = await offer(in: webView, origin: origin) else { return [] }
        return await items(for: offer)
    }

    /// Signs in with `passkey`: the page's waiting request makes way for one for it alone, and the Mac's sheet asks
    /// for Touch ID. Run with the click's user gesture, which WebKit wants for a passkey sheet. False when the page
    /// no longer waits for it.
    func use(_ passkey: SavedPasskey, in webView: WKWebView) async -> Bool {
        let chosen = try? await webView.callAsyncJavaScript("return window[Symbol.for('zigzag.passkeys')]?.choose?.(id) ?? false",
                                                            arguments: ["id": passkey.id], in: nil, contentWorld: .page)
        return chosen as? Bool == true
    }
}
