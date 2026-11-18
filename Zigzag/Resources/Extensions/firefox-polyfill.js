// Firefox's two runtime members WebKit has no counterpart for (firefox-polyfill.js).
//
// WebKit already gives a Firefox add-on a promise-based `browser`, so nothing here wraps or copies the API. A copy
// would lose what WebKit keeps on a prototype (storage.local.get/set lives there), and answering runtime.id with a
// gecko ID gave a value no message's sender.id matched. What is added is only what Firefox has and WebKit does not,
// on WebKit's own object, so a listener or a method read through `browser` is the one WebKit delivers through.
//
// The prelude is injected once per profile, into every extension's pages and background, so it cannot know what kind
// of package it is in. The package's own manifest does: a Firefox one carries browser_specific_settings (or the older
// applications), a Chrome one has neither. Without them nothing is touched, so an extension in a Chrome package keeps
// exactly the `browser` WebKit gave it.
(() => {
  // The app's own version and machine architecture, written in by ExtensionBridge.swift: what a Firefox extension
  // asking getBrowserInfo is told as the browser's version, and what the platform answer falls back to. Neither is
  // the extension manifest's.
  const appVersion = __ZIGZAG_VERSION__;
  const appArch = __ZIGZAG_ARCH__;
  // What Firefox says of the machine it runs on. The architecture comes from this build, never a literal: Firefox's
  // binding design spells an Apple-silicon Mac's `aarch64`.
  const FIREFOX_PLATFORM = { os: 'mac', arch: appArch };
  // Firefox's spelling of the machine's architecture (WebKit reports Chrome's).
  const firefoxArch = (arch) => arch === 'arm64' ? 'aarch64'
    : (arch === 'x86-64' || arch === 'x86_64') ? 'x86-64'
    : typeof arch === 'string' && arch ? arch : FIREFOX_PLATFORM.arch;

  // Zigzag's own answer: the extension is running in a browser that is not Firefox. Firefox says Mozilla as its
  // vendor, and Zigzag is not Mozilla's, so it names itself there too.
  const getBrowserInfo = () => Promise.resolve({ name: 'Zigzag', vendor: 'Zigzag', version: appVersion, buildID: '' });

  // Firefox's own answer for one runtime. Zigzag has no runtime.getPlatformInfo of its own, and WebKit may not either:
  // where WebKit answers, its answer is made Firefox's. Where it doesn't, the API surface has already stood an
  // `unavailable` stand-in in its place, which answers with a rejection ("… isn't available in Zigzag"). A rejection
  // or a throw means WebKit has none, so Firefox's own answer stands, rather than the surface's refusal.
  //
  // WebKit's own member is taken now, before this replaces it: read at call time from the object it was set on, it
  // would be this very function.
  const getPlatformInfo = (runtime) => {
    const native = runtime.getPlatformInfo;
    return () => {
      const none = () => ({ os: FIREFOX_PLATFORM.os, arch: FIREFOX_PLATFORM.arch });
      if (typeof native !== 'function') return Promise.resolve(none());
      let answer;
      try { answer = Reflect.apply(native, runtime, []); }
      catch (e) { return Promise.resolve(none()); }
      if (!answer || typeof answer.then !== 'function') return Promise.resolve(none());
      return Promise.resolve(answer).then(
        (info) => ({ os: info && typeof info.os === 'string' && info.os ? info.os : FIREFOX_PLATFORM.os,
                     arch: firefoxArch(info && info.arch) }),
        none);
    };
  };

  // A member WebKit doesn't have, set on its own object. Where WebKit won't be set, the differences' helper hides it
  // behind a stand-in for the object that holds it, as the rest of the corrections do.
  const put = (runtime, key, value) => {
    try { Object.defineProperty(runtime, key, { value, configurable: true, enumerable: true, writable: true }); } catch (e) {}
    if (runtime[key] === value) return;
    if (typeof globalThis.__zigzagSetMember === 'function') globalThis.__zigzagSetMember(['runtime'], key, value);
  };

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
      done = true;   // A Chrome package: nothing of Firefox's is added to it.
      return true;
    }

    // WebKit's own `browser` is what a Firefox package uses, and it is the object these members go on: `chrome` is
    // left as it was, the surface's stand-ins included.
    const target = (globalThis.browser && globalThis.browser.runtime) || api.runtime;
    put(target, 'getBrowserInfo', getBrowserInfo);
    put(target, 'getPlatformInfo', getPlatformInfo(target));
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
