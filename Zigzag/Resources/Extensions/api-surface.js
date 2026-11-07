// The rest of Chrome's extension API, so an extension never meets `undefined` where Chrome has something.
//
// Runs after the bridge and the compatibility layer, in an extension's background and pages. `surface` is every
// Chrome namespace with its functions, events, constants, enums and objects (chrome-api.json, written from Chrome's
// own definitions by scripts/chrome-api.py). Anything WebKit, the bridge or the compatibility layer already provides
// is left as it is; what's still missing is added, for namespaces the extension asked permission for: constants and
// enums with Chrome's values, events that never fire, and functions that say they aren't available (a rejected
// promise, or the callback with nothing). Such a call is noted once in the extensions log, so what an extension
// needed and didn't get is on record.
(() => {
  const surface = __SURFACE__;
  const start = () => {
    const api = globalThis.chrome || globalThis.browser;
    if (globalThis.__zigzagSurface) return true;
    if (!api || !api.runtime) return false;
    globalThis.__zigzagSurface = true;

    let manifest = {};
    try { manifest = api.runtime.getManifest() || {}; } catch (e) {}
    const asked = new Set([...(manifest.permissions || []), ...(manifest.optional_permissions || [])]);
    const inWorker = typeof window === 'undefined';
    const noted = new Set();
    const note = (name) => {
      if (noted.has(name)) return;
      noted.add(name);
      try { api.runtime.sendNativeMessage('zigzag.diagnostics', { where: 'surface', kind: 'unavailable', text: name }); } catch (e) {}
    };
    const unavailable = (name) => (...args) => {
      note(name);
      const callback = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (callback) { setTimeout(() => { try { callback(); } catch (e) { console.error(e); } }, 0); return undefined; }
      return Promise.reject(new Error(`${name} isn't available in Zigzag`));
    };
    const event = () => ({
      addListener() {}, removeListener() {}, hasListener: () => false, hasListeners: () => false,
      addRules(rules, callback) { if (typeof callback === 'function') setTimeout(() => callback([]), 0); },
      getRules(ids, callback) { const cb = typeof ids === 'function' ? ids : callback; if (typeof cb === 'function') setTimeout(() => cb([]), 0); },
      removeRules(ids, callback) { const cb = typeof ids === 'function' ? ids : callback; if (typeof cb === 'function') setTimeout(() => cb(), 0); },
    });
    // WebKit names some features with nothing behind them: `in` isn't enough, and plain assignment can fail quietly.
    const put = (target, key, value) => {
      if (target[key] != null) return target[key];
      try { Object.defineProperty(target, key, { value, configurable: true, enumerable: true, writable: true }); } catch (e) { return null; }
      return target[key];
    };
    const fill = (target, spec, name) => {
      for (const fn of spec.functions || []) if (typeof target[fn] !== 'function') put(target, fn, unavailable(`${name}.${fn}`));
      for (const ev of spec.events || []) put(target, ev, event());
      for (const [key, value] of Object.entries(spec.constants || {})) if (target[key] === undefined) put(target, key, value);
      for (const [key, values] of Object.entries(spec.enums || {})) if (target[key] === undefined) put(target, key, Object.freeze({ ...values }));
      for (const [key, inner] of Object.entries(spec.objects || {})) {
        const object = put(target, key, {});
        if (!object || typeof object !== 'object') continue;
        if (inner.properties) for (const [prop, members] of Object.entries(inner.properties)) {
          const child = put(object, prop, {});
          if (child && typeof child === 'object') fill(child, members, `${name}.${key}.${prop}`);
        } else fill(object, inner, `${name}.${key}`);
      }
    };
    const available = (spec) => {
      for (const flag of spec.flags || []) {
        const [kind, value = ''] = flag.split('=');
        if (kind === 'chrome-platform' && !value.split(' ').includes('mac')) return false;
        if (kind === 'chrome-channel' && value && value !== 'stable') return false;
        if (kind === 'chrome-install-location') return false;
        if (kind === 'chrome-disallow-service-workers' && inWorker) return false;
      }
      return !(spec.permissions || []).length || spec.permissions.some((permission) => asked.has(permission));
    };
    for (const target of new Set([globalThis.chrome, globalThis.browser])) {
      if (!target) continue;
      for (const [path, spec] of Object.entries(surface)) {
        // DevTools pages only, and those get their own from WebKit. userScripts stays missing until a user turns it
        // on even in Chrome, so extensions check for it and take another way: present, it would send them down this one.
        if (path.startsWith('devtools.') || path === 'userScripts' || !available(spec)) continue;
        let namespace = target;
        for (const part of path.split('.')) {
          namespace = namespace && put(namespace, part, {});
        }
        if (namespace && typeof namespace === 'object') fill(namespace, spec, `chrome.${path}`);
      }
    }
    return true;
  };
  if (!start()) {
    let tries = 0;
    const again = () => { if (!start() && ++tries < 100) setTimeout(again, 20); };
    setTimeout(again, 0);
  }
})();
