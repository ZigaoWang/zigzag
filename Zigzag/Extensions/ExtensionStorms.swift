import AppKit
import WebKit

/// Throttles a content script that reconnects to its background in a tight loop.
///
/// Some extensions reconnect a port from every frame as soon as it closes (vuex-webextensions' store sync). When the
/// background rejects each one, it loops as fast as WebKit allows: thousands of connects per second, each hitting
/// Zigzag's main thread (WebKit asks for the sender's tab and window). A background Sound Booster page kept the app
/// busy (2026-11).
///
/// WebKit gives the app no hook into a content script's `runtime.connect`, so this runs first in the extension's
/// content-script world (listed first in each manifest entry of the loaded copy). Once a frame's connect rate stays far
/// above normal, it lets one through at intervals and queues the rest. Ports that get through work normally. Each
/// world counts its own; other extensions and frames are untouched.
nonisolated enum ConnectGuard {
    /// Guard file in the loaded copy.
    static let file = "zigzag-connect-guard.js"
    /// Message handler name, from the extension's content-script world only.
    static let handlerName = "zigzagExtensionStorm"

    /// Throttle a frame above this many connects per second for `seconds` in a row. Normal extensions open one or two per
    /// frame load (1Password one per frame, Tampermonkey one per script request); loops do hundreds to thousands.
    static let perSecond = 50
    static let seconds = 5
    /// While throttled, one connect goes through after this delay, doubling while each closes at once, up to `maxGap`.
    static let firstGap = 1_000
    static let maxGap = 30_000
    /// A port that stays open this long ends the throttle.
    static let calm = 10_000
    /// Max queued connects; past it the newest are dropped.
    static let queue = 100

    /// Content scripts with the guard first in each entry for the extension's world. `"world": "MAIN"` entries are left
    /// alone; page scripts aren't the extension's.
    static func guarding(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.map { entry in
            guard (entry["world"] as? String)?.uppercased() != "MAIN", let js = entry["js"] as? [String], !js.isEmpty,
                  !js.contains(file) else { return entry }
            var guarded = entry
            guarded["js"] = [file] + js
            return guarded
        }
    }

    /// The guard. `install(runtime, now, later, report, limits)` wraps one `runtime.connect`; runs on the world's
    /// `chrome.runtime` (and `browser.runtime` if different), once per frame.
    static let source = """
    (() => {
      'use strict';
      const install = (runtime, now, later, report, limits) => {
        const native = runtime && runtime.connect;
        if (typeof native !== 'function' || native.__zigzagGuard) return null;
        const L = Object.assign({ perSecond: \(perSecond), seconds: \(seconds), firstGap: \(firstGap), maxGap: \(maxGap), calm: \(calm), queue: \(queue) }, limits || {});
        let second = -1, count = 0, streak = 0, peak = 0;
        let held = false, told = false, gap = L.firstGap, nextAt = 0, pumping = false;
        // The last port let through while throttled: when, whether open, whether it closed at once.
        let openedAt = 0, open = false, quick = false;
        const waiting = [];
        const rethrow = (e) => later(() => { throw e; }, 0);
        const each = (list, ...args) => { for (const f of list.slice()) { try { f(...args); } catch (e) { rethrow(e); } } };
        // Counted per clock second; consecutive seconds over the limit extend the run.
        const tick = () => {
          const s = Math.floor(now() / 1000);
          if (s !== second) {
            const hot = count > L.perSecond;
            if (hot) peak = Math.max(peak, count);
            streak = hot && s === second + 1 ? streak + 1 : 0;
            second = s;
            count = 0;
          }
          count += 1;
          if (!held && count > L.perSecond && streak + 1 >= L.seconds) {
            held = true;
            gap = L.firstGap;
            nextAt = 0;
            if (!told) { told = true; try { report({ kind: 'connect', perSecond: Math.max(peak, count) }); } catch (e) {} }
          }
        };
        // Returns a port now that connects on its turn; messages queue until then.
        const deferred = (args) => {
          const messages = [], gone = [], outbox = [];
          let real = null, closed = false;
          const event = (list) => ({
            addListener: (f) => { if (typeof f === 'function' && !list.includes(f)) list.push(f); },
            removeListener: (f) => { const i = list.indexOf(f); if (i >= 0) list.splice(i, 1); },
            hasListener: (f) => list.includes(f),
            hasListeners: () => list.length > 0,
          });
          const info = args.find((a) => a && typeof a === 'object') || {};
          const port = {
            name: typeof info.name === 'string' ? info.name : '',
            sender: undefined,
            onMessage: event(messages),
            onDisconnect: event(gone),
            postMessage(message) {
              if (closed) throw new Error('Attempting to use a disconnected port object');
              if (real) real.postMessage(message); else outbox.push(message);
            },
            disconnect() {
              if (closed) return;
              closed = true;
              if (real) { try { real.disconnect(); } catch (e) {} }
            },
          };
          const connect = () => {
            if (closed) return;
            try { real = native.apply(runtime, args); } catch (e) { closed = true; each(gone, port); return; }
            const mine = real;
            openedAt = now(); open = true; quick = false;
            try { port.sender = mine.sender; } catch (e) {}
            mine.onMessage.addListener((message) => each(messages, message, port));
            mine.onDisconnect.addListener(() => {
              closed = true;
              if (real === mine) { open = false; quick = now() - openedAt < 1000; }
              // Read inside the listener, where runtime.lastError is expected.
              each(gone, port);
            });
            for (const message of outbox.splice(0)) mine.postMessage(message);
          };
          return { port, connect };
        };
        const pump = () => {
          pumping = false;
          if (!waiting.length) return;
          const t = now();
          if (t < nextAt) { pumping = true; later(pump, nextAt - t); return; }
          // Still closing right away: double the wait.
          if (quick) gap = Math.min(gap * 2, L.maxGap);
          nextAt = t + gap;
          waiting.shift()();
          if (waiting.length) { pumping = true; later(pump, gap); }
        };
        const wrapped = function connect(...args) {
          tick();
          // The port stayed open: loop over.
          if (held && open && now() - openedAt >= L.calm) { held = false; streak = 0; count = 0; }
          if (!held) return native.apply(runtime, args);
          const made = deferred(args);
          if (waiting.length >= L.queue) return made.port;
          waiting.push(made.connect);
          if (!pumping) { pumping = true; later(pump, Math.max(0, nextAt - now())); }
          return made.port;
        };
        wrapped.__zigzagGuard = true;
        // WebKit recreates API objects without their properties once unreferenced; hold this one so `chrome.runtime` keeps
        // the wrapper (as the compatibility layer does).
        (globalThis.__zigzagHeld = globalThis.__zigzagHeld || []).push(runtime);
        try { runtime.connect = wrapped; } catch (e) {}
        if (runtime.connect !== wrapped) {
          try { Object.defineProperty(runtime, 'connect', { value: wrapped, configurable: true, writable: true }); } catch (e) {}
        }
        return { isHeld: () => held, gap: () => gap, waiting: () => waiting.length };
      };
      globalThis.__zigzagConnectGuard = install;
      if (globalThis.__zigzagConnectGuarded) return;
      const report = (info) => {
        try {
          const handler = globalThis.webkit && globalThis.webkit.messageHandlers && globalThis.webkit.messageHandlers.\(handlerName);
          const sent = handler && handler.postMessage(info);
          if (sent && sent.catch) sent.catch(() => {});
        } catch (e) {}
      };
      const runtimes = new Set([globalThis.chrome && globalThis.chrome.runtime, globalThis.browser && globalThis.browser.runtime].filter(Boolean));
      if (!runtimes.size) return;
      globalThis.__zigzagConnectGuarded = true;
      for (const runtime of runtimes) install(runtime, () => Date.now(), (f, ms) => setTimeout(f, ms), report);
    })();

    """
}

/// Starts a service worker background that a content script's message is waiting on.
///
/// WebKit stops an idle service worker and should start it again for the next message. Sometimes it doesn't: the
/// content script's `runtime.sendMessage` then waits for good, with no answer and no error, until something else
/// starts the background (a click on the extension's button). 1Password's field menu and its fill of the next sign-in
/// step wait on such messages, so they stopped working until the button was clicked (2026-11).
///
/// This runs in the extension's content-script world, after ConnectGuard. A message still unanswered after `wait`
/// tells Zigzag, which asks WebKit to start the background; one already running is left as it is. A frame tells at
/// most once per `gap`, and Zigzag asks at most once per `gap` per extension.
nonisolated enum BackgroundWake {
    static let wait = 3_000
    static let gap = 10_000
    static let kind = "unanswered"

    /// `install(runtime, later, now, tell)` wraps one `runtime.sendMessage`; runs on the world's `chrome.runtime` (and
    /// `browser.runtime` if different), once per frame. Answers and errors reach the caller as before.
    static let source = """
    (() => {
      'use strict';
      const install = (runtime, later, cancel, now, tell) => {
        const native = runtime && runtime.sendMessage;
        if (typeof native !== 'function' || native.__zigzagWakes) return false;
        let toldAt = -Infinity;
        const unanswered = () => {
          if (now() - toldAt < \(gap)) return;
          toldAt = now();
          try { tell({ kind: '\(kind)' }); } catch (e) {}
        };
        const wrapped = function sendMessage(...args) {
          let timer = later(unanswered, \(wait));
          const done = () => { if (timer !== null) { cancel(timer); timer = null; } };
          const last = args.length - 1;
          if (last >= 0 && typeof args[last] === 'function') {
            const callback = args[last];
            // Read inside the callback, where runtime.lastError is expected.
            args[last] = function (...values) { done(); return callback.apply(this, values); };
          }
          let result;
          try { result = native.apply(runtime, args); } catch (error) { done(); throw error; }
          if (result && typeof result.then === 'function') result.then(done, done);
          return result;
        };
        wrapped.__zigzagWakes = true;
        (globalThis.__zigzagHeld = globalThis.__zigzagHeld || []).push(runtime);
        try { runtime.sendMessage = wrapped; } catch (e) {}
        if (runtime.sendMessage !== wrapped) {
          try { Object.defineProperty(runtime, 'sendMessage', { value: wrapped, configurable: true, writable: true }); } catch (e) {}
        }
        return runtime.sendMessage === wrapped;
      };
      globalThis.__zigzagBackgroundWake = install;
      if (globalThis.__zigzagWakesBackground || typeof document === 'undefined') return;
      const tell = (info) => {
        const handler = globalThis.webkit && globalThis.webkit.messageHandlers && globalThis.webkit.messageHandlers.\(ConnectGuard.handlerName);
        const sent = handler && handler.postMessage(info);
        if (sent && sent.catch) sent.catch(() => {});
      };
      const runtimes = new Set([globalThis.chrome && globalThis.chrome.runtime, globalThis.browser && globalThis.browser.runtime].filter(Boolean));
      if (!runtimes.size) return;
      globalThis.__zigzagWakesBackground = true;
      for (const runtime of runtimes) install(runtime, (f, ms) => setTimeout(f, ms), (id) => clearTimeout(id), () => Date.now(), tell);
    })();

    """

    /// The extensions log's lines for wakes: the first ask, the first failure for each extension in a session, and,
    /// once its background does start, how many asks had failed. Nothing else, so a background that keeps failing
    /// writes one line, not one every `gap`.
    struct Log {
        private var failures: [String: Int] = [:]

        mutating func started(_ id: String, name: String, first: Bool) -> String? {
            if let failed = failures.removeValue(forKey: id) {
                return "\(name): its background started after \(failed) \(failed == 1 ? "ask" : "asks") that didn't start it"
            }
            return first ? "\(name): a page's message waited on its background; asked it to start" : nil
        }

        mutating func failed(_ id: String, name: String, error: String) -> String? {
            let count = failures[id, default: 0] + 1
            failures[id] = count
            return count == 1 ? "\(name): a page's message waited on its background, which didn't start: \(error)" : nil
        }
    }

    /// Whether Zigzag asks WebKit again: not within `gap` of the last time for the same extension.
    static func due(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) * 1000 >= Double(gap)
    }
}

/// Handles a throttled content script (ConnectGuard): logs once and shows one window notice naming the extension, with
/// a way to turn it off.
@available(macOS 15.4, *)
@MainActor
final class ExtensionStorms {
    unowned let host: ExtensionHost
    /// Throttled extensions per tab, for EnergyWatch's busy tab note.
    private var byTab: [UUID: Set<String>] = [:]
    /// Extension and site pairs already logged; one line each.
    private var logged: Set<String> = []
    /// Lines logged this launch, capped so one extension can't fill the log.
    private var lines = 0
    static let maxLines = 50

    init(host: ExtensionHost) { self.host = host }

    /// Throttled extensions in a tab, by ID.
    func extensions(in tab: Tab) -> Set<String> { byTab[tab.id] ?? [] }

    /// A frame's guard throttled its extension.
    func receive(_ message: WKScriptMessage) {
        guard let world = message.world.name, world.hasPrefix("WebExtension-") else { return }
        let id = String(world.dropFirst("WebExtension-".count))
        if (message.body as? [String: Any])?["kind"] as? String == BackgroundWake.kind {
            wakeBackground(id)
            return
        }
        guard let context = host.context(for: id), let tab = (message.webView as? BrowserWebView)?.owner,
              byTab[tab.id]?.contains(id) != true else { return }
        let rate = ((message.body as? [String: Any])?["perSecond"] as? NSNumber)?.intValue ?? 0
        noted(id, name: context.webExtension.displayName ?? id, rate: rate, in: tab)
    }

    /// When each extension's background was last asked to start (BackgroundWake).
    private var wokenAt: [String: Date] = [:]

    /// A content script's message went unanswered: asks WebKit to start the background, which does nothing to one
    /// that's running.
    func wakeBackground(_ id: String) {
        guard let context = host.context(for: id), context.webExtension.hasBackgroundContent,
              BackgroundWake.due(last: wokenAt[id], now: Date()) else { return }
        let first = wokenAt[id] == nil
        wokenAt[id] = Date()
        let name = context.webExtension.displayName ?? id
        Task {
            do {
                try await context.loadBackgroundContent()
                if let line = self.wakeLog.started(id, name: name, first: first) { ExtensionLog.write(line) }
            } catch {
                if let line = self.wakeLog.failed(id, name: name, error: error.localizedDescription) { ExtensionLog.write(line) }
            }
        }
    }

    /// What the extensions log says of the wakes (BackgroundWake).
    private var wakeLog = BackgroundWake.Log()

    func noted(_ id: String, name: String, rate: Int, in tab: Tab) {
        guard byTab[tab.id]?.contains(id) != true else { return }
        byTab[tab.id, default: []].insert(id)
        // Drop closed tabs.
        if byTab.count > 200 {
            let open = Set(WindowManager.shared.everyOpenTab.map(\.id))
            byTab = byTab.filter { open.contains($0.key) }
        }
        let site = Self.loggedSite(tab.url, isPrivate: tab.isPrivate)
        if logged.insert(id + "|" + site).inserted, lines < Self.maxLines {
            lines += 1
            ExtensionLog.write("\(name) reconnected to its background \(rate) times a second on \(site); held back there to one try a second or less")
        }
        EnergyWatch.shared.extensionIsBusy(id, name: name, in: tab, host: host)
    }

    /// The site named in the log; a private tab's is left out.
    static func loggedSite(_ url: URL?, isPrivate: Bool) -> String {
        isPrivate ? "a private page" : ContentBlocker.site(of: url) ?? "a page"
    }
}
