// Firefox's Promise `browser` API, built over the Chrome surface Zigzag answers (firefox-polyfill.js).
//
// Zigzag's surface is Chrome's: a call that takes a trailing callback answers through it, or answers a Promise, and a
// failure comes back as chrome.runtime.lastError or a rejected Promise. A Firefox extension instead calls browser.*
// and expects a Promise (and reads a few members at once). So `browser` here is a facade over `chrome`: each
// function answers a Promise, the handful Firefox answers at once are passed through, and events are the same
// objects WebKit delivers through, so a listener added through `browser` is one the bridge and WebKit see.
//
// The prelude is injected once per profile, into every extension's pages and background, so it cannot know what kind
// of package it is in. The package's own manifest does: a Firefox one carries browser_specific_settings (or the
// older applications), a Chrome one has neither. Without them, whatever `browser` was found is left exactly as it
// was — an extension in a Chrome package keeps Chrome's API and its callbacks.
(() => {
  let done = false;
  const start = () => {
    if (done) return true;
    // Whatever WebKit gave the extension: `chrome`, or `browser` where that is all there is.
    const api = globalThis.chrome || globalThis.browser;
    if (!api || !api.runtime || typeof api.runtime.getManifest !== 'function') return false;

    let manifest = null;
    try { manifest = api.runtime.getManifest() || null; } catch (e) { return false; }
    // Mozilla's mark on the package: the newer key, or the one before it.
    if (!manifest || !(manifest.browser_specific_settings || manifest.applications)) {
      done = true;   // A Chrome package: `browser` is not Firefox's to have.
      return true;
    }
    const gecko = (manifest.browser_specific_settings && manifest.browser_specific_settings.gecko)
      || (manifest.applications && manifest.applications.gecko)
      || null;
    const geckoID = gecko && typeof gecko.id === 'string' ? gecko.id : null;

    // What Firefox answers at once, exactly; every other function answers a Promise.
    const SYNC = new Set(['runtime.getManifest', 'runtime.getURL', 'runtime.id',
      'i18n.getMessage', 'i18n.getUILanguage', 'i18n.getAcceptLanguages']);

    // A rejection as Firefox's: an object whose `message` carries the error's words.
    const fail = (error) => ({ message: error && error.message != null ? String(error.message) : String(error) });

    // One function, answered as a Promise. Zigzag's surface answers a Promise when no callback is passed — the
    // bridge, the compatibility layer and the differences all do — which is what a Firefox caller wants. A failure
    // of the call, or of the answer, is normalized here.
    const promised = new WeakMap();
    const asPromise = (fn, self) => {
      let wrapper = promised.get(fn);
      if (wrapper) return wrapper;
      wrapper = (...args) => {
        let answer;
        try { answer = Reflect.apply(fn, self, args); }
        catch (error) { return Promise.reject(fail(error)); }
        if (answer && typeof answer.then === 'function') {
          return answer.then((value) => value, (error) => { throw fail(error); });
        }
        return Promise.resolve(answer);
      };
      promised.set(fn, wrapper);
      return wrapper;
    };

    // What Firefox answers at once: the function itself, bound to the object it belongs to.
    const bound = new WeakMap();
    const asSync = (fn, self) => {
      let wrapper = bound.get(fn);
      if (wrapper) return wrapper;
      wrapper = fn.bind(self);
      bound.set(fn, wrapper);
      return wrapper;
    };

    // WebKit's events, left as they are: a listener added through `browser` is one WebKit and the bridge look for.
    const isEvent = (value) => value && typeof value === 'object' && typeof value.addListener === 'function';

    // Firefox-only members. getBrowserInfo says what Firefox says of its browser here — Zigzag. Zigzag has no
    // runtime.getPlatformInfo of its own: the surface's, where it stood one up, answers; only when there is none
    // does Firefox's own answer stand.
    const getBrowserInfo = () => Promise.resolve({ name: 'Zigzag', vendor: 'Lakeland97' });
    const getPlatformInfo = () => {
      const native = api.runtime.getPlatformInfo;
      if (typeof native === 'function') return asPromise(native, api.runtime)();
      return Promise.resolve({ os: 'mac' });
    };

    // One namespace's facade: its own object, over `target`'s members. A member is read the first time it is asked
    // for, so an object that appears later — an extension page gets its `chrome` a moment after the prelude runs —
    // is still found, and nothing is built that is never used.
    const facades = new WeakMap();
    const facade = (target, path) => {
      const held = facades.get(target);
      if (held) return held;
      const out = {};
      facades.set(target, out);
      const seen = new Map();
      for (const key of Object.getOwnPropertyNames(target)) {
        const where = path ? path + '.' + key : key;
        // These three are Firefox's view, defined below whatever the surface holds.
        if (where === 'runtime.id' || where === 'runtime.getBrowserInfo' || where === 'runtime.getPlatformInfo') continue;
        const descriptor = Object.getOwnPropertyDescriptor(target, key);
        Object.defineProperty(out, key, {
          configurable: true, enumerable: descriptor ? descriptor.enumerable : true,
          get() {
            if (seen.has(key)) return seen.get(key);
            let value;
            try { value = target[key]; } catch (e) { return undefined; }
            let made = value;
            if (isEvent(value)) made = value;
            else if (value && typeof value === 'object') made = facade(value, where);
            else if (typeof value === 'function') made = SYNC.has(where) ? asSync(value, target) : asPromise(value, target);
            seen.set(key, made);
            return made;
          },
        });
      }
      if (path === 'runtime') {
        Object.defineProperty(out, 'id', {
          configurable: true, enumerable: true,
          get() { return geckoID != null ? geckoID : target.id; },
        });
        out.getBrowserInfo = getBrowserInfo;
        out.getPlatformInfo = getPlatformInfo;
      }
      return out;
    };

    const browser = facade(api, '');
    // By assignment, or by definition where something (keepsBrowser) put a setter in the way.
    try {
      Object.defineProperty(globalThis, 'browser', { value: browser, configurable: true, enumerable: true, writable: true });
    } catch (e) {
      try { globalThis.browser = browser; } catch (e2) {}
    }
    done = true;
    return true;
  };
  // An extension page gets its `chrome` a moment after the prelude runs; this still comes before its own timers.
  if (!start()) {
    let tries = 0;
    const again = () => { if (!start() && ++tries < 100) setTimeout(again, 20); };
    setTimeout(again, 0);
  }
})();
