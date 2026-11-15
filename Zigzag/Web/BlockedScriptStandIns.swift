import WebKit

/// Stand-ins for tracking libraries the content blocker stops, on sites that can't start without them.
///
/// EasyPrivacy blocks FingerprintJS 2 (`/fingerprint2.min.js` and the like) everywhere. Some sites call it from their
/// own code before anything else, so with the file blocked `Fingerprint2` is never defined, the first call throws, and
/// the page stays blank (中语智汇's web.zyamoy.com, a teaching platform schools use). uBlock Origin serves a harmless
/// file in its place; WebKit's content blocker can only stop a request, so pages that are blocked for get a small
/// stand-in instead, there only when the page asked for the library and the library never came. It answers
/// FingerprintJS 2's calls with no fingerprint: one random ID per site, kept with that site's own data, so the site
/// sees the same browser from visit to visit and learns nothing about the Mac.
///
/// This is for any site, as uBlock Origin's `fingerprint2.js` is. A fix for one site goes in the "Zigzag fixes" list
/// (AdFilters.swift), not here, unless the site breaks on a block the content blocker makes whether or not that list
/// has reached the page (`siteCalls`).
enum BlockedScriptStandIns {
    /// The file names EasyPrivacy blocks FingerprintJS 2 by.
    static let fingerprint2Files = #"/(?:fingerprint2(?:\.min)?|fp2\.min|fp2\.compressed|fpt2)\.js(?:[?#]|$)"#

    private static let mark = "/* zigzag blocked script stand-ins */"

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(mark) }

    /// With the content blocker on a page, or not: the stand-ins go with it (ContentBlocker.apply).
    static func apply(_ wanted: Bool, to controller: WKUserContentController) {
        let has = controller.userScripts.filter(isOurs).map(\.source)
        if wanted { for script in scripts where !has.contains(script.source) { controller.addUserScript(script) } }
        if !wanted, !has.isEmpty { OwnScripts.remove(from: controller, where: isOurs) }
    }

    static var scripts: [WKUserScript] { [script, siteCalls] }

    /// A site's own calls the content blocker stops, each on the one host it was seen on, that the site reads as a
    /// broken network. Their fetch and XMLHttpRequest get an empty answer from the page itself: nothing is sent, as
    /// with the block.
    ///
    /// DeepSeek (chat.deepseek.com) posts its telemetry to /api/v0/telemetry, which EasyPrivacy blocks; after three
    /// failures in a row, while its other calls go through, it says "Please check your browser extensions" (#208).
    /// The "Zigzag fixes" list answers it too, but only once uBlock Origin's lists and scriptlets have downloaded, only
    /// in pages loaded after that (a pinned DeepSeek restored at launch while the lists are rebuilt after an update
    /// kept failing until it was reloaded), and never beside an ad blocker extension. This block is Zigzag's own and
    /// always there with it, so its answer is too.
    static let siteCalls = WKUserScript(source: """
    \(mark)
    (() => {
      const calls = { 'chat.deepseek.com': /^\\/api\\/v0\\/telemetry\\/?$/ };
      const path = calls[location.hostname];
      if (!path) return;
      const answered = (address) => {
        try {
          const url = new URL(String(address), location.href);
          return url.origin === location.origin && path.test(url.pathname);
        } catch (e) { return false; }
      };
      // Proxies, so fetch and XMLHttpRequest still read as the browser's own to the page.
      window.fetch = new Proxy(window.fetch, {
        apply(target, self, args) {
          const input = args[0];
          if (answered(input instanceof Request ? input.url : input)) return Promise.resolve(new Response('', { status: 200, statusText: 'OK' }));
          return Reflect.apply(target, self, args);
        },
      });
      const proto = XMLHttpRequest.prototype;
      const opened = new WeakMap();
      proto.open = new Proxy(proto.open, {
        apply(target, self, args) {
          if (answered(args[1])) opened.set(self, new URL(String(args[1]), location.href).href); else opened.delete(self);
          return Reflect.apply(target, self, args);
        },
      });
      proto.send = new Proxy(proto.send, {
        apply(target, self, args) {
          const url = opened.get(self);
          if (!url) return Reflect.apply(target, self, args);
          const answer = { readyState: 4, status: 200, statusText: 'OK', responseText: '', response: '', responseURL: url };
          for (const [name, value] of Object.entries(answer)) Object.defineProperty(self, name, { value, configurable: true });
          setTimeout(() => { for (const type of ['readystatechange', 'load', 'loadend']) self.dispatchEvent(new ProgressEvent(type)); });
        },
      });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    static let script = WKUserScript(source: """
    \(mark)
    (() => {
      const blocked = new RegExp(\(String(reflecting: fingerprint2Files)), 'i');
      const hash = (text, seed) => {
        text = String(text); let out = '';
        for (let lane = 0; lane < 4; lane++) {
          let h = (0x811c9dc5 ^ (seed | 0) ^ Math.imul(lane + 1, 0x9e3779b9)) >>> 0;
          for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 0x01000193); }
          h ^= h >>> 16; h = Math.imul(h, 0x85ebca6b); h ^= h >>> 13; h = Math.imul(h, 0xc2b2ae35); h ^= h >>> 16;
          out += (h >>> 0).toString(16).padStart(8, '0');
        }
        return out;
      };
      let made = null;
      const standIn = () => {
        if (made) return made;
        const key = '__zigzagBrowserID';
        let id = '';
        try { id = localStorage.getItem(key) || ''; } catch (e) {}
        if (!id) {
          id = Array.from(crypto.getRandomValues(new Uint32Array(4)), (n) => n.toString(16).padStart(8, '0')).join('');
          try { localStorage.setItem(key, id); } catch (e) {}
        }
        const components = () => [{ key: 'id', value: id }];
        const later = (callback, ...args) => { if (typeof callback === 'function') setTimeout(() => callback(...args), 1); };
        made = function Fingerprint2() {};
        made.VERSION = '2.1.4';
        made.get = (options, callback) => later(callback || options, components());
        made.getPromise = () => Promise.resolve(components());
        made.getV18 = (options, callback) => later(callback || options, hash(id, 31), components());
        made.x64hash128 = hash;
        made.prototype.get = (options, callback) => later(callback || options, hash(id, 31), components());
        return made;
      };
      // Whether the page asked for the library: one of its scripts is at one of the blocked addresses.
      const askedFor = () => Array.prototype.some.call(document.scripts, (script) => blocked.test(script.src));
      // A blocked script fails without holding back the page's next one, and says so only later, so the stand-in is
      // there to be read from the start. The real library, where it loads, puts itself in its place.
      if (!('Fingerprint2' in window)) {
        Object.defineProperty(window, 'Fingerprint2', {
          configurable: true,
          get: () => (askedFor() ? standIn() : undefined),
          set: (value) => Object.defineProperty(window, 'Fingerprint2', { value, writable: true, configurable: true, enumerable: true }),
        });
      }
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
}
