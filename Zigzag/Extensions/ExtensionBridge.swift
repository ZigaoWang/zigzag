import Foundation
import WebKit

/// Chrome extension APIs that WebKit doesn't have, answered by Zigzag itself.
///
/// An extension's scripts call `chrome.history.search(…)` as they would in Chrome. The bridge script
/// (Resources/Extensions/bridge.js, run before the extension's own code in its background and pages) turns that into
/// a native message to `zigzag.bridge`, which lands here and is handed to the namespace that answers it. Events
/// (`chrome.history.onVisited`) go the other way over a port the script opens only once something listens.
///
/// Every call is checked against what the person approved for the extension: one that wasn't allowed "history" can't
/// read history through the bridge, whatever its scripts send, and one whose files now ask for more (an extension read
/// from a folder can change them) gets it only once the person allows it (ExtensionHost.restoreGrants). Private
/// windows show through only to an extension allowed in them.
@available(macOS 15.4, *)
@MainActor
final class ExtensionBridge {
    /// The name extensions' scripts send their calls to.
    static let hostName = "zigzag.bridge"

    /// The extensions it answers: one profile's. What a namespace keeps by an extension's ID is kept here, so two
    /// profiles' copies of the same extension never see each other's.
    unowned let host: ExtensionHost
    private let namespaces: [String: any BridgeNamespace]
    /// Side panels, which the toolbar's click handling asks first (ExtensionHost.performAction).
    let sidePanel: BridgeSidePanel
    /// Offscreen pages, which runtime.getContexts reports.
    let offscreen: BridgeOffscreen
    /// Tab capture, whose captures end with the popup that made them.
    let tabCapture: BridgeTabCapture
    /// Proxy settings, put back at launch before any page loads.
    let proxy: BridgeProxy
    /// Sites' own sign-ins, which extensions' onAuthRequired listeners may answer before the sheet asks.
    let webRequest: BridgeWebRequest
    /// User scripts, which every web view of the profile runs (Tab attaches its own).
    let userScripts: BridgeUserScripts
    /// Address bar keywords, which the command bar hands what's typed after them.
    let omnibox: BridgeOmnibox
    /// The browser's password saving, as password managers set it.
    let passwordSaving: BridgePasswordSaving
    /// Open event ports, by extension, with the events each has listeners for.
    private var ports: [ObjectIdentifier: (port: WKWebExtension.MessagePort, id: String, events: Set<String>)] = [:]

    /// Namespaces the bridge handles (`history`, `system.display`). Overlay `swift:` claims must name one of these.
    static let handlerNames: Set<String> = Set(handlerTypes.map { $0.name })

    /// Handler class names (`BridgeContexts`), which a claim may use instead of the namespace (`contexts`).
    static let handlerTypeNames: Set<String> = Set(handlerTypes.map { String(describing: $0) })

    /// One handler per namespace. `init` creates the profile-owned ones; the rest are per profile too.
    private static let handlerTypes: [any BridgeNamespace.Type] = [
        BridgeHistory.self, BridgeTopSites.self, BridgeSessions.self, BridgeBookmarks.self, BridgeDownloads.self,
        BridgeNotifications.self, BridgeIdle.self, BridgeDisplay.self, BridgeContexts.self,
        BridgeRuntime.self, BridgeSpeech.self, BridgePower.self, BridgeIdentity.self,
        BridgeFavicons.self, BridgeExtensionFetch.self, BridgeContextMenus.self,
        BridgeOffscreen.self, BridgeSidePanel.self, BridgeTabCapture.self, BridgeProxy.self,
        BridgeWebRequest.self, BridgeUserScripts.self, BridgeOmnibox.self, BridgePasswordSaving.self,
    ]

    init(host: ExtensionHost) {
        self.host = host
        sidePanel = BridgeSidePanel(host: host)
        offscreen = BridgeOffscreen(host: host)
        tabCapture = BridgeTabCapture(host: host)
        proxy = BridgeProxy(host: host)
        webRequest = BridgeWebRequest(host: host)
        userScripts = BridgeUserScripts(host: host)
        omnibox = BridgeOmnibox(host: host)
        passwordSaving = BridgePasswordSaving(host: host)
        let direct: [any BridgeNamespace] = [offscreen, sidePanel, tabCapture, proxy, webRequest, userScripts, omnibox, passwordSaving]
        let directNames = Set(direct.map { type(of: $0).name })
        let others = Self.handlerTypes.filter { !directNames.contains($0.name) }.map { $0.init(host: host) }
        let all: [any BridgeNamespace] = others + direct
        namespaces = Dictionary(uniqueKeysWithValues: all.map { (type(of: $0).name, $0) })
    }

    // MARK: Calls

    /// One call: `{ ns, fn, args }`. Answers `{ value }`, or `{ error }` with a message the extension can show.
    func handle(_ message: Any, from context: WKWebExtensionContext, reply: @escaping (Any?, (any Error)?) -> Void) {
        guard let body = message as? [String: Any], let ns = body["ns"] as? String, let fn = body["fn"] as? String,
              let namespace = namespaces[ns] else {
            reply(["error": "Unknown call"], nil)
            return
        }
        let id = context.uniqueIdentifier
        guard Self.allows(type(of: namespace).permission, for: context) else {
            reply(["error": "\(ns) needs the “\(type(of: namespace).permission)” permission"], nil)
            return
        }
        let args = body["args"] as? [Any] ?? []
        let host = host
        Task { @MainActor in
            do {
                // A queued fetch must not inherit a replacement context's grants after unload/reload.
                if ns == BridgeExtensionFetch.name, host.context(for: id) !== context {
                    throw BridgeError("The extension is no longer loaded.")
                }
                let value = try await namespace.call(fn, args: args, extensionID: id)
                reply(["value": Self.plain(value) ?? NSNull()], nil)
            } catch {
                let text = (error as? BridgeError)?.message ?? error.localizedDescription
                // In the extensions log, so "it didn't work" can be traced to the call that said no.
                ExtensionLog.write("\(context.webExtension.displayName ?? id) \(ns).\(fn) failed: \(text)")
                reply(["error": text], nil)
            }
        }
    }

    /// Whether the extension may use a permission: the person granted it (when they approved the extension or an
    /// update, or allowed it later), and its own manifest still asks for it. The manifest alone is never enough: what
    /// a folder's files ask for can change behind the person's back. The loaded copy's manifest also asks for native
    /// messaging, so the package's own is what's read.
    static func allows(_ permission: String, for context: WKWebExtensionContext) -> Bool {
        // Namespaces about the extension's own pages need no permission.
        if permission.isEmpty { return true }
        return allows(permission, declared: ExtensionStore.declaredPermissions(context.uniqueIdentifier), granted: context.grantedPermissions)
    }

    /// Asked for (required or optional), and granted and not yet expired. WebKit keeps permissions it doesn't know
    /// itself (the bridge's) among the granted ones too.
    static func allows(_ permission: String, declared: (required: Set<String>, optional: Set<String>),
                       granted: [WKWebExtension.Permission: Date], now: Date = Date()) -> Bool {
        guard declared.required.contains(permission) || declared.optional.contains(permission) else { return false }
        return granted[WKWebExtension.Permission(rawValue: permission)].map { $0 > now } ?? false
    }

    /// The same, by the extension's ID, for namespaces that check a further permission ("downloads.open").
    func allows(_ permission: String, for extensionID: String) -> Bool {
        host.context(for: extensionID).map { Self.allows(permission, for: $0) } ?? false
    }

    // MARK: Events

    /// The event port: the script says which events it listens to (`{ listen: ["history.onVisited"] }`).
    func connect(_ port: WKWebExtension.MessagePort, for context: WKWebExtensionContext) {
        let key = ObjectIdentifier(port)
        ports[key] = (port, context.uniqueIdentifier, [])
        port.messageHandler = { [weak self, weak context] message, _ in
            guard let self, let context, let events = (message as? [String: Any])?["listen"] as? [String] else { return }
            // Only events of namespaces it may use.
            let allowed = events.filter { name in
                guard let ns = name.split(separator: ".").first.map(String.init), let namespace = self.namespaces[ns] else { return false }
                return Self.allows(type(of: namespace).permission, for: context)
            }
            self.ports[key]?.events.formUnion(allowed)
            for ns in Set(allowed.compactMap { $0.split(separator: ".").first.map(String.init) }) {
                self.namespaces[ns]?.startEvents()
            }
        }
        port.disconnectHandler = { [weak self] _ in self?.ports[key] = nil }
    }

    /// Whether any extension listens to an event, so a namespace only watches (idle, say) while someone cares.
    func isListened(_ event: String, by extensionID: String? = nil) -> Bool {
        ports.values.contains { $0.events.contains(event) && (extensionID == nil || $0.id == extensionID) }
    }

    /// Tells every extension listening to `event` (all of them, or only `extensionID`). About a private window
    /// (`isPrivate`), only those allowed in private windows.
    func emit(_ event: String, _ args: [Any], to extensionID: String? = nil, isPrivate: Bool = false) {
        let payload: [String: Any] = ["event": event, "args": Self.plain(args) ?? []]
        for entry in ports.values where entry.events.contains(event) && (extensionID == nil || entry.id == extensionID)
            && PrivateAccess.sees(isPrivate: isPrivate, allowed: host.seesPrivate(entry.id)) {
            entry.port.sendMessage(payload, completionHandler: nil)
        }
    }

    /// An extension turned off or removed: whatever it held (a keep-awake, a voice) is let go.
    func release(_ extensionID: String) {
        for namespace in namespaces.values { namespace.release(extensionID) }
        ports = ports.filter { $0.value.id != extensionID }
    }

    // MARK: Values

    /// Only what JSON can carry crosses to the extension: dates become Chrome's milliseconds, optionals drop out.
    static func plain(_ value: Any?) -> Any? {
        switch value {
        case nil: return nil
        case let date as Date: return date.timeIntervalSince1970 * 1000
        case let array as [Any?]: return array.compactMap { plain($0) ?? NSNull() }
        case let dictionary as [String: Any?]: return dictionary.compactMapValues { plain($0) }
        case let string as String: return string
        case let number as NSNumber: return number
        case let bool as Bool: return bool
        case let int as Int: return int
        case let double as Double: return double
        default: return nil
        }
    }
}

/// A failure to say to the extension, in words.
nonisolated struct BridgeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
    static func unsupported(_ ns: String, _ fn: String) -> BridgeError { BridgeError("\(ns).\(fn) isn't available in Zigzag") }
}

/// The script side of the bridge (Resources/Extensions/bridge.js), run before an extension's own code.
enum ExtensionBridgeScript {
    /// The permissions whose APIs the bridge answers, so the install sheet doesn't list them as missing.
    static let permissions: Set<String> = ["history", "topSites", "sessions", "bookmarks", "downloads", "downloads.open", "notifications", "idle", "tts", "power", "offscreen", "identity", "sidePanel", "tabCapture", "system.display", "userScripts", "proxy", "webRequestAuthProvider"]
    /// Permissions the bridge grants and records because WebKit drops them: its own, and MV2 webRequestBlocking, which
    /// sign-ins need (BridgeWebRequest) even though blocking doesn't work.
    static let granted: Set<String> = permissions.union(["webRequestBlocking"])

    static let source: String = {
        guard let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    /// Where WebKit answers differently from Chrome, made to answer as Chrome does (webkit-differences.js).
    static let differences: String = keepsBrowser + "\n" + storageInOrder + "\n" + idleCallbacks + "\n" + webLocks + "\n" + differencesSource

    /// Storage calls answer in the order made, as in Chrome; WebKit can answer a get before an earlier set (#350).
    nonisolated static let storageInOrder = """
    (() => {
      const lines = {};
      const kept = new Set();
      const reads = ['get', 'getKeys', 'getBytesInUse'];
      const order = (area, name) => {
        if (!area || typeof area !== 'object' || kept.has(area)) return;
        kept.add(area);
        const line = lines[name] || (lines[name] = { writes: null, all: null, open: 0 });
        for (const method of [...reads, 'set', 'remove', 'clear', 'setAccessLevel']) {
          const native = area[method];
          if (typeof native !== 'function') continue;
          const write = !reads.includes(method);
          const inOrder = function (...args) {
            const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
            const ahead = write ? line.all : line.writes;
            let finish;
            const done = new Promise((resolve) => { finish = resolve; });
            line.open++;
            const mine = done.then(() => { if (--line.open === 0) { line.writes = null; line.all = null; } });
            line.all = line.all ? Promise.all([line.all, mine]) : mine;
            if (write) line.writes = line.all;
            const start = () => {
              try {
                if (callback) {
                  native.call(area, ...args, function (...values) { finish(); return callback.apply(this, values); });
                  return undefined;
                }
                const answer = native.apply(area, args);
                Promise.resolve(answer).then(finish, finish);
                return answer;
              } catch (error) { finish(); throw error; }
            };
            if (!ahead) return start();
            const started = ahead.then(start);
            if (!callback) return started;
            started.catch((error) => { setTimeout(() => { throw error; }); });
            return undefined;
          };
          try { Object.defineProperty(area, method, { value: inOrder, configurable: true, writable: true }); } catch (e) {}
        }
      };
      const wrap = () => {
        const roots = [...new Set([globalThis.chrome, globalThis.browser])].filter((root) => root && root.storage);
        for (const root of roots) {
          kept.add(root.storage);
          for (const name of ['local', 'sync', 'session']) order(root.storage[name], name);
        }
        return roots.length > 0;
      };
      if (wrap() || typeof document === 'undefined') return;
      let tries = 0;
      const again = () => { if (!wrap() && ++tries < 100) setTimeout(again, 20); };
      setTimeout(again, 0);
    })();
    """

    /// Keeps the global `browser` as WebKit's API in backgrounds, pages and content scripts. WebKit looks up listeners
    /// through that global on every delivery (message, port, event); Chrome doesn't. Proton Pass replaces `chrome` and
    /// `browser` with inert stand-ins after starting, so its background never heard its popup (#287). Chrome has no
    /// `browser` of its own, so here assigning it does nothing. `chrome` is left to the extension; WebKit doesn't deliver
    /// through it.
    nonisolated static let keepsBrowser = """
    (() => {
      const keep = () => {
        const native = globalThis.browser;
        if (!native || typeof native !== 'object' || !native.runtime) return false;
        const own = Object.getOwnPropertyDescriptor(globalThis, 'browser');
        if (own && (own.get || own.configurable === false)) return true;
        try {
          Object.defineProperty(globalThis, 'browser', { get: () => native, set: () => {}, configurable: true, enumerable: own ? own.enumerable : false });
        } catch (e) {}
        return true;
      };
      if (keep() || typeof document === 'undefined') return;
      // An extension page may get its API after this runs; this still runs before the page's timers.
      let tries = 0;
      const again = () => { if (!keep() && ++tries < 100) setTimeout(again, 20); };
      setTimeout(again, 0);
    })();
    """

    /// requestIdleCallback where WebKit has none, in the extension's pages and content scripts: Chrome has it, and
    /// Proton Pass's content script stopped on it before putting its icon in sign-in fields (#287).
    nonisolated static let idleCallbacks = """
    (() => {
      if (typeof document === 'undefined' || typeof globalThis.requestIdleCallback === 'function') return;
      const timers = new Map();
      let last = 0;
      globalThis.requestIdleCallback = function requestIdleCallback(callback) {
        if (typeof callback !== 'function') throw new TypeError("Failed to execute 'requestIdleCallback' on 'Window': parameter 1 is not of type 'Function'.");
        const id = ++last;
        timers.set(id, setTimeout(() => {
          timers.delete(id);
          const began = Date.now();
          callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - began)) });
        }, 1));
        return id;
      };
      globalThis.cancelIdleCallback = function cancelIdleCallback(id) {
        clearTimeout(timers.get(id));
        timers.delete(id);
      };
    })();
    """

    /// A message nothing listens for: Chrome fails tabs.sendMessage and runtime.sendMessage with this, WebKit answers
    /// undefined, as when a listener gives no answer. Extensions take the error to mean their content script isn't in
    /// the tab yet, inject it and send again; given undefined, they waited.
    nonisolated static let noReceiver = "Could not establish connection. Receiving end does not exist."
    /// `receivers` as a file of the loaded copy, which bridge.js runs in a tab's frames to ask whether they listen.
    nonisolated static let receiversFile = "zigzag-receivers.js"
    nonisolated static let receiversMark = "__zigzagListeners:"

    /// Runs in the extension's content-script world, before its content scripts (ExtensionStore.contentScriptsFirst)
    /// and, as `receiversFile`, before files it injects or registers and when bridge.js asks. It counts the world's
    /// runtime.onMessage listeners, which WebKit can't say; its last line answers whether there are any. And it fails
    /// an unanswered runtime.sendMessage when none of the extension's pages listens (webkit-differences.js answers for
    /// them), as Chrome does. Once per world.
    nonisolated static let receivers = """
    (() => {
      'use strict';
      if (typeof globalThis.__zigzagMessageListeners === 'function') return;
      const runtimes = [...new Set([globalThis.chrome, globalThis.browser].map((api) => api && api.runtime).filter(Boolean))];
      const held = (globalThis.__zigzagHeld = globalThis.__zigzagHeld || []);
      held.push(...runtimes);
      const put = (object, name, value) => {
        try { object[name] = value; } catch (e) {}
        if (object[name] !== value) { try { Object.defineProperty(object, name, { value, configurable: true, writable: true }); } catch (e) {} }
        return object[name] === value;
      };
      // Where a listener can't be counted, the world says it listens.
      const listening = new Set();
      let unsure = !runtimes.length;
      const events = [];
      for (const runtime of runtimes) {
        const event = runtime.onMessage;
        if (!event || typeof event.addListener !== 'function') { unsure = true; continue; }
        if (events.includes(event)) continue;
        events.push(event);
        held.push(event);
        const add = event.addListener, remove = event.removeListener;
        const added = put(event, 'addListener', function addListener(listener, ...rest) {
          const result = add.call(event, listener, ...rest);
          if (typeof listener === 'function') listening.add(listener);
          return result;
        });
        const removed = typeof remove !== 'function' || put(event, 'removeListener', function removeListener(listener, ...rest) {
          listening.delete(listener);
          return remove.call(event, listener, ...rest);
        });
        if (!added || !removed) unsure = true;
      }
      Object.defineProperty(globalThis, '__zigzagMessageListeners', { value: () => unsure || listening.size > 0, configurable: true });

      const withError = (callback, error) => {
        const lastError = { message: String((error && error.message) || error) };
        const before = runtimes.map((runtime) => Object.getOwnPropertyDescriptor(runtime, 'lastError'));
        for (const runtime of runtimes) { try { Object.defineProperty(runtime, 'lastError', { get: () => lastError, configurable: true }); } catch (e) {} }
        try { callback(); } finally {
          runtimes.forEach((runtime, index) => {
            try { if (before[index]) Object.defineProperty(runtime, 'lastError', before[index]); else delete runtime.lastError; } catch (e) {}
          });
        }
      };
      // A listener found is trusted for a few seconds.
      let foundAt = -Infinity;
      for (const runtime of runtimes) {
        const native = runtime.sendMessage;
        if (typeof native !== 'function' || native.__zigzagChecksReceiver) continue;
        const listens = () => {
          if (Date.now() - foundAt < 10000) return Promise.resolve(true);
          return Promise.resolve().then(() => native.call(runtime, { \(receiverProbe): true }))
            .then((answer) => { if (answer === true) foundAt = Date.now(); return answer === true; }, () => null);
        };
        const sendMessage = function sendMessage(...args) {
          const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
          // To another extension: as WebKit has it.
          if (args.length >= 2 && typeof args[0] === 'string' && args[0] !== runtime.id) return native.apply(runtime, callback ? [...args, callback] : args);
          const result = Promise.resolve(native.apply(runtime, args)).then((value) => {
            if (value !== undefined) { foundAt = Date.now(); return value; }
            return listens().then((yes) => { if (yes === false) throw new Error('\(noReceiver)'); return undefined; });
          });
          if (!callback) return result;
          result.then((value) => callback(value), (error) => withError(callback, error));
          return undefined;
        };
        sendMessage.__zigzagChecksReceiver = true;
        put(runtime, 'sendMessage', sendMessage);
      }
    })();
    '\(receiversMark)' + (typeof globalThis.__zigzagMessageListeners !== 'function' || globalThis.__zigzagMessageListeners());
    """
    nonisolated static let receiverProbe = "__zigzagReceiverProbe"

    /// The stand-in for navigator.locks (web-locks.js); also goes in front of worker scripts that use it.
    static let webLocks: String = {
        Bundle.main.url(forResource: "web-locks", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }()
    static let webLocksMark = "zigzag.webLocks"

    private static let differencesSource: String = {
        Bundle.main.url(forResource: "webkit-differences", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }()

    /// Zigzag's own version, which a Firefox extension asking runtime.getBrowserInfo is told as the browser's. Read as
    /// the rest of the app reads it; empty where there is no bundle to read it from (the local test build).
    static let firefoxAppVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// firefox-polyfill.js with the app version filled in; it acts only for a Firefox-kind record.
    static let firefoxPolyfill: String = {
        guard let url = Bundle.main.url(forResource: "firefox-polyfill", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.replacingOccurrences(of: "__ZIGZAG_VERSION__", with: jsString(firefoxAppVersion))
    }()

    /// A Swift string as a JavaScript string literal, for the values written into the scripts.
    private static func jsString(_ text: String) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: [text])) ?? Data(), encoding: .utf8)
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    /// Everything Zigzag puts before an extension's own code, after the bridge and the compatibility layer.
    static var afterCompatibility: String { differences + "\n" + surface + "\n" + firefoxPolyfill }

    /// The rest of Chrome's API, from Chrome's own definitions (api-surface.js over chrome-api.json): runs after the
    /// bridge and the compatibility layer, and fills only what's still missing.
    static let surface: String = {
        guard let script = Bundle.main.url(forResource: "api-surface", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
              let data = Bundle.main.url(forResource: "chrome-api", withExtension: "json").flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
        else { return "" }
        return script.replacingOccurrences(of: "__SURFACE__", with: data)
    }()
}

/// One Chrome namespace the bridge answers.
@available(macOS 15.4, *)
@MainActor
protocol BridgeNamespace: AnyObject {
    /// The namespace's name, as in `chrome.<name>`.
    static var name: String { get }
    /// The manifest permission an extension needs to use it.
    static var permission: String { get }
    /// Made for one profile's extensions.
    init(host: ExtensionHost)
    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any?
    /// Something now listens to this namespace's events: start watching for them, if it needs to.
    func startEvents()
    /// The extension is gone: let go of anything kept for it.
    func release(_ extensionID: String)
}

@available(macOS 15.4, *)
extension BridgeNamespace {
    func startEvents() {}
    func release(_ extensionID: String) {}
}

extension Int {
    /// A number an extension passed, as a whole number: past Int's range it's the nearest end, NaN is 0, a fraction
    /// is cut off. Never a trap, which `Int(_: Double)` is for any of those first two, so one call can't crash Zigzag.
    init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= Double(Int.max) {
            self = .max
        } else if value <= Double(Int.min) {
            self = .min
        } else {
            self = Int(value)
        }
    }
}

/// Reading arguments as Chrome passes them: an options object, a string, a number.
extension Array where Element == Any {
    func object(_ index: Int) -> [String: Any] { indices.contains(index) ? self[index] as? [String: Any] ?? [:] : [:] }
    func string(_ index: Int) -> String? { indices.contains(index) ? self[index] as? String : nil }
    func number(_ index: Int) -> Double? { indices.contains(index) ? (self[index] as? NSNumber)?.doubleValue : nil }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func number(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    /// Chrome's times are milliseconds since 1970.
    func date(_ key: String) -> Date? { number(key).map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// The name macOS knows an extension's notification by: whose it is, so a click on it reaches the extension that made
/// it, in the profile it's in. The first profile's keep the form they've always had.
nonisolated struct ExtensionNotificationKey: Equatable {
    static let prefix = "ext|"
    /// Nil for the first profile.
    var profile: UUID?
    var extensionID: String
    var id: String

    init(profile: UUID?, extensionID: String, id: String) {
        self.profile = profile
        self.extensionID = extensionID
        self.id = id
    }

    /// From a notification's name; nil if it isn't an extension's. An extension's ID is never a UUID, so a UUID in
    /// first place is a profile.
    init?(_ string: String) {
        guard string.hasPrefix(Self.prefix) else { return nil }
        let rest = string.dropFirst(Self.prefix.count)
        let first = rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard first.count == 2 else { return nil }
        if let profile = UUID(uuidString: first[0]) {
            let parts = first[1].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            self.init(profile: profile, extensionID: parts[0], id: parts[1])
        } else {
            self.init(profile: nil, extensionID: first[0], id: first[1])
        }
    }

    var string: String {
        Self.prefix + (profile.map { "\($0.uuidString)|" } ?? "") + "\(extensionID)|\(id)"
    }
}
