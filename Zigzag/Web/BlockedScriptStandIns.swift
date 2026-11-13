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
enum BlockedScriptStandIns {
    /// The file names EasyPrivacy blocks FingerprintJS 2 by.
    static let fingerprint2Files = #"/(?:fingerprint2(?:\.min)?|fp2\.min|fp2\.compressed|fpt2)\.js(?:[?#]|$)"#

    private static let mark = "/* zigzag blocked script stand-ins */"

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(mark) }

    /// With the content blocker on a page, or not: the stand-ins go with it (ContentBlocker.apply).
    static func apply(_ wanted: Bool, to controller: WKUserContentController) {
        let has = controller.userScripts.contains(where: isOurs)
        if wanted, !has { controller.addUserScript(script) }
        if !wanted, has { OwnScripts.remove(from: controller, where: isOurs) }
    }

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
