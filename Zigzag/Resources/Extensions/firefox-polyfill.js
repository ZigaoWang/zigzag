// Firefox's runtime member WebKit has no counterpart for (firefox-polyfill.js): getBrowserInfo.
//
// WebKit already gives a Firefox add-on a promise-based `browser`, so nothing here wraps or copies the API. A copy
// would lose what WebKit keeps on a prototype (storage.local.get/set lives there), and answering runtime.id with a
// gecko ID gave a value no message's sender.id matched. What is added is only what Firefox has and WebKit does not,
// on WebKit's own object, so a listener or a method read through `browser` is the one WebKit delivers through.
//
// The prelude is injected once per profile, into every extension's pages and background, so it cannot know what kind
// of package it is in. Zigzag's record of the install does, and it sets __zigzagFirefoxPackage in that extension's own
// preludes (ExtensionStore.shim(for:)). The manifest cannot decide it: Chrome Web Store packages often carry Firefox's
// browser_specific_settings too. Without the marker nothing is touched, so a Chrome package keeps exactly the `browser`
// WebKit gave it.
(() => {
  // The app's own version, written in by ExtensionBridge.swift: what a Firefox extension asking getBrowserInfo is
  // told as the browser's version. It is not the extension manifest's.
  const appVersion = __ZIGZAG_VERSION__;

  // Zigzag's own answer: the extension is running in a browser that is not Firefox. Firefox says Mozilla as its
  // vendor, and Zigzag is not Mozilla's, so it names itself there too.
  const getBrowserInfo = () => Promise.resolve({ name: 'Zigzag', vendor: 'Zigzag', version: appVersion, buildID: '' });

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

    // The installed record's kind, set by Zigzag, not the manifest: a Chrome Web Store package may carry
    // browser_specific_settings too, and WebKit tells no extension which store it came from.
    // WebKit's own `browser` is what a Firefox package uses, and it is the object these members go on: `chrome` is
    // left as it was, the surface's stand-ins included.
    const addMembers = () => put((globalThis.browser && globalThis.browser.runtime) || api.runtime, 'getBrowserInfo', getBrowserInfo);
    done = true;
    if (globalThis.__zigzagFirefoxPackage === true) { addMembers(); return true; }
    // A Chrome package: nothing of Firefox's is added to it. The marker of a Firefox package installed after the
    // profile's pages were set up comes after this script (ExtensionHost.addFirefoxMarker), and still adds them.
    try {
      Object.defineProperty(globalThis, '__zigzagFirefoxPackage', { configurable: true, get: () => false, set: (value) => {
        if (value !== true) return;
        Object.defineProperty(globalThis, '__zigzagFirefoxPackage', { value: true, configurable: true, writable: true });
        addMembers();
      } });
    } catch (e) {}
    return true;
  };
  // An extension page gets its `chrome` a moment after the prelude runs; this still comes before its own timers.
  if (!start()) {
    let tries = 0;
    const again = () => { if (!start() && ++tries < 100) setTimeout(again, 20); };
    setTimeout(again, 0);
  }
})();
