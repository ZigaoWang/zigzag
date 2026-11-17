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
  // The app's own version and machine architecture, written in by ExtensionBridge.swift: what a Firefox extension
  // asking getBrowserInfo is told as the browser's version, and what the platform answer falls back to. Neither is
  // the extension manifest's.
  const appVersion = __ZIGZAG_VERSION__;
  const appArch = __ZIGZAG_ARCH__;
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

    // Firefox-only members. getBrowserInfo says what Firefox says of its browser here — Zigzag, at the app's own
    // version.
    //
    // Zigzag has no runtime.getPlatformInfo of its own, and WebKit may not either. Where WebKit answers, its answer
    // is made Firefox's. Where it doesn't, the API surface has already stood an `unavailable` stand-in in its place,
    // and that stand-in answers with a rejection ("chrome.runtime.getPlatformInfo isn't available in Zigzag"). A
    // rejection or a throw means WebKit has none, so Firefox's own answer stands — the surface's refusal must not
    // reach the extension in its place. That answer is the app's own architecture, in Firefox's spelling, written in
    // by ExtensionBridge.swift: a build on another machine says its own, never a literal.
    const FIREFOX_PLATFORM = { os: 'mac', arch: appArch };
    // Firefox's spelling of the machine's architecture (WebKit reports Chrome's).
    const firefoxArch = (arch) => arch === 'arm64' ? 'aarch64'
      : (arch === 'x86-64' || arch === 'x86_64') ? 'x86-64'
      : typeof arch === 'string' && arch ? arch : FIREFOX_PLATFORM.arch;
    const getBrowserInfo = () => Promise.resolve({ name: 'Zigzag', vendor: 'Lakeland97', version: appVersion, buildID: '' });
    const getPlatformInfo = () => {
      const none = () => ({ os: FIREFOX_PLATFORM.os, arch: FIREFOX_PLATFORM.arch });
      const native = api.runtime.getPlatformInfo;
      if (typeof native !== 'function') return Promise.resolve(none());
      let answer;
      try { answer = Reflect.apply(native, api.runtime, []); }
      catch (e) { return Promise.resolve(none()); }
      if (!answer || typeof answer.then !== 'function') return Promise.resolve(none());
      return Promise.resolve(answer).then(
        (info) => ({ os: info && typeof info.os === 'string' && info.os ? info.os : FIREFOX_PLATFORM.os,
                     arch: firefoxArch(info && info.arch) }),
        none);
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
