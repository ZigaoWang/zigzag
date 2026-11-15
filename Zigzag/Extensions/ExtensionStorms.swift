import AppKit
import WebKit

/// Holds back an extension's content script that reconnects to its background in a tight loop.
///
/// Some extensions open a port from every frame and open another the moment it closes (vuex-webextensions' store
/// sync does). When their background turns each one away, that loops as fast as WebKit can carry it: thousands of
/// connections a second, each one passing through Zigzag's main thread (WebKit asks which tab, window and place the
/// sender is in), which kept the app busy with a page in the background (a Sound Booster, 2026-11).
///
/// WebKit gives the app no say in a content script's `runtime.connect`: the call goes from the page's process to the
/// extension's background without asking. So the extension's own content-script world gets this first, ahead of its
/// scripts (the loaded copy's manifest lists it first in each entry): it counts the frame's connects and, only once
/// they stay far past anything a working extension does, lets one through every so often instead of every one, the
/// rest waiting their turn. Ports keep working once through, so a loop that settles goes on as before. Nothing else
/// about the extension changes, and other extensions and frames are never touched: each world counts its own.
nonisolated enum ConnectGuard {
    /// The guard's file in the loaded copy.
    static let file = "zigzag-connect-guard.js"
    /// What it tells Zigzag through, from the extension's content-script world only.
    static let handlerName = "zigzagExtensionStorm"

    /// Past this many connects in one second, every second for `seconds` in a row, a frame is held back. A working
    /// extension opens a port or two as a frame loads (1Password one per frame, Tampermonkey one per script's
    /// request): far under. A loop runs at hundreds to thousands.
    static let perSecond = 50
    static let seconds = 5
    /// Held back, one connect goes through after this long, then after twice that while each still closes at once,
    /// up to `maxGap`.
    static let firstGap = 1_000
    static let maxGap = 30_000
    /// A port let through that stays open this long means the loop is over: the frame connects freely again.
    static let calm = 10_000
    /// Connects waiting their turn, at most; past it, the newest wait for nothing.
    static let queue = 100

    /// The content scripts as the loaded copy runs them: the guard first in each entry that runs in the extension's
    /// own world. One for the page's world (`"world": "MAIN"`) is left alone: the page's scripts aren't the extension's.
    static func guarding(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.map { entry in
            guard (entry["world"] as? String)?.uppercased() != "MAIN", let js = entry["js"] as? [String], !js.isEmpty,
                  !js.contains(file) else { return entry }
            var guarded = entry
            guarded["js"] = [file] + js
            return guarded
        }
    }

    /// The guard. `install(runtime, now, later, report, limits)` wraps one `runtime` object's `connect`; the file runs it
    /// on the world's own `chrome.runtime` (and `browser.runtime` if that's another object), once per frame however
    /// many entries list it.
    static let source = """
    (() => {
      'use strict';
      const install = (runtime, now, later, report, limits) => {
        const native = runtime && runtime.connect;
        if (typeof native !== 'function' || native.__zigzagGuard) return null;
        const L = Object.assign({ perSecond: \(perSecond), seconds: \(seconds), firstGap: \(firstGap), maxGap: \(maxGap), calm: \(calm), queue: \(queue) }, limits || {});
        let second = -1, count = 0, streak = 0, peak = 0;
        let held = false, told = false, gap = L.firstGap, nextAt = 0, pumping = false;
        // The last port let through while held back: when, whether it's still open, whether it closed at once.
        let openedAt = 0, open = false, quick = false;
        const waiting = [];
        const rethrow = (e) => later(() => { throw e; }, 0);
        const each = (list, ...args) => { for (const f of list.slice()) { try { f(...args); } catch (e) { rethrow(e); } } };
        // Counted by the clock's second: a second past the limit right after another one adds to the run.
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
        // A port handed back at once that connects when its turn comes; until then what's sent on it waits.
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
              // Read inside the listener, where the extension expects runtime.lastError to be set.
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
          // Still closing as soon as it opens: the next waits twice as long.
          if (quick) gap = Math.min(gap * 2, L.maxGap);
          nextAt = t + gap;
          waiting.shift()();
          if (waiting.length) { pumping = true; later(pump, gap); }
        };
        const wrapped = function connect(...args) {
          tick();
          // The port let through has stayed open: the loop is over.
          if (held && open && now() - openedAt >= L.calm) { held = false; streak = 0; count = 0; }
          if (!held) return native.apply(runtime, args);
          const made = deferred(args);
          if (waiting.length >= L.queue) return made.port;
          waiting.push(made.connect);
          if (!pumping) { pumping = true; later(pump, Math.max(0, nextAt - now())); }
          return made.port;
        };
        wrapped.__zigzagGuard = true;
        // WebKit makes its API objects afresh once nothing holds them, without what was set on them: held, so the
        // extension's `chrome.runtime` stays this one (as the compatibility layer holds what it fills).
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

/// What Zigzag does when an extension's content script was held back (ConnectGuard): says so once in the extensions
/// log, and once in the window, naming the extension, with a way to turn it off.
@available(macOS 15.4, *)
@MainActor
final class ExtensionStorms {
    unowned let host: ExtensionHost
    /// Extensions held back in each tab, by tab: what EnergyWatch names for a busy tab.
    private var byTab: [UUID: Set<String>] = [:]
    /// Extension and site pairs already written to the log: one line each, however many frames say so.
    private var logged: Set<String> = []
    /// Lines written since Zigzag started: a cap, so even an extension held back on every site can't fill the log.
    private var lines = 0
    static let maxLines = 50

    init(host: ExtensionHost) { self.host = host }

    /// The extensions held back in a tab, by ID.
    func extensions(in tab: Tab) -> Set<String> { byTab[tab.id] ?? [] }

    /// A frame's guard held its extension back.
    func receive(_ message: WKScriptMessage) {
        guard let world = message.world.name, world.hasPrefix("WebExtension-") else { return }
        let id = String(world.dropFirst("WebExtension-".count))
        guard let context = host.context(for: id), let tab = (message.webView as? BrowserWebView)?.owner,
              byTab[tab.id]?.contains(id) != true else { return }
        let rate = ((message.body as? [String: Any])?["perSecond"] as? NSNumber)?.intValue ?? 0
        noted(id, name: context.webExtension.displayName ?? id, rate: rate, in: tab)
    }

    func noted(_ id: String, name: String, rate: Int, in tab: Tab) {
        guard byTab[tab.id]?.contains(id) != true else { return }
        byTab[tab.id, default: []].insert(id)
        // Tabs gone since are let go.
        if byTab.count > 200 {
            let open = Set(WindowManager.shared.controllers.flatMap { $0.tabManager.allTabs.map(\.id) })
            byTab = byTab.filter { open.contains($0.key) }
        }
        let site = ContentBlocker.site(of: tab.url) ?? "a page"
        if logged.insert(id + "|" + site).inserted, lines < Self.maxLines {
            lines += 1
            ExtensionLog.write("\(name) reconnected to its background \(rate) times a second on \(site); held back there to one try a second or less")
        }
        EnergyWatch.shared.extensionIsBusy(id, name: name, in: tab, host: host)
    }
}
