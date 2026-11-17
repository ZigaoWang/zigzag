// The rest of Chrome's extension API, so an extension never meets `undefined` where Chrome has something.
//
// Runs after the bridge and the compatibility layer, in an extension's background and pages. `surface` is every
// Chrome namespace with its functions, events, constants, enums and objects (chrome-api.json, written from Chrome's
// own definitions by scripts/chrome-api.py). Anything WebKit, the bridge or the compatibility layer already provides
// is left as it is; what's still missing is added, for namespaces the extension asked permission for: constants and
// enums with Chrome's values, events that never fire but remember their listeners, and functions that fail as
// Chrome's do when an API is missing: a callback runs asynchronously with `runtime.lastError` set and no result, or a
// promise rejects with an `Error`. Such a call is noted once in the extensions log, so what an extension needed and
// didn't get is on record.
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
    // Chrome's runtime.getContexts is MV3's alone. An MV2 extension has no member at all, not even a stand-in that
    // would make feature detection take the wrong path.
    const mv3 = manifest.manifest_version === 3;
    // Members Chrome added with MV3: an MV2 extension has none of them, not even a constant its feature detection
    // would find. Only the members Chrome reserves for MV3 belong here, never every constant of a namespace.
    const mv3Only = { 'chrome.runtime': new Set(['ContextType']) };
    const inWorker = typeof window === 'undefined';
    const noted = new Set();
    const note = (name) => {
      if (noted.has(name)) return;
      noted.add(name);
      try { api.runtime.sendNativeMessage('zigzag.diagnostics', { where: 'surface', kind: 'unavailable', text: name }); } catch (e) {}
    };
    // The runtime objects as they are now: an extension may hold one of these while its global `chrome` changes.
    const runtimes = [];
    for (const target of [globalThis.chrome, globalThis.browser]) {
      try {
        if (target && target.runtime && !runtimes.includes(target.runtime)) runtimes.push(target.runtime);
      } catch (e) {}
    }
    const errorFor = (name) => ({ message: `${name} isn't available in Zigzag` });
    // Chrome's lastError is there only while a failing callback runs. WebKit keeps one of its own on the runtime, so
    // save it, stand a getter in its place for the callback, and put it back even when the callback throws.
    const withLastError = (name, run) => {
      const error = errorFor(name);
      const saved = runtimes.map((runtime) => [runtime, Object.getOwnPropertyDescriptor(runtime, 'lastError')]);
      try {
        for (const runtime of runtimes) {
          try {
            Object.defineProperty(runtime, 'lastError', { get: () => error, configurable: true, enumerable: true });
          } catch (e) {
            // One WebKit won't let us shadow: assign it where we can, and say so.
            try { runtime.lastError = error; } catch (e2) {}
            note('runtime.lastError (unshadowed)');
          }
        }
        run();
      } finally {
        for (const [runtime, descriptor] of saved) {
          try {
            if (descriptor) Object.defineProperty(runtime, 'lastError', descriptor);
            else delete runtime.lastError;
          } catch (e) {}
        }
      }
    };
    const unavailable = (name) => (...args) => {
      note(name);
      const callback = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (callback) {
        setTimeout(() => {
          try { withLastError(name, () => callback()); } catch (e) { console.error(e); }
        }, 0);
        return undefined;
      }
      return Promise.reject(new Error(errorFor(name).message));
    };
    // An event that can't fire still takes and remembers its listeners, as an extension registering at the top of
    // its background expects.
    const event = () => {
      const listeners = new Set();
      const later = (run) => setTimeout(() => {
        try { withLastError('rules', run); } catch (e) { console.error(e); }
      }, 0);
      return {
        addListener(listener) { if (typeof listener === 'function') listeners.add(listener); },
        removeListener(listener) { listeners.delete(listener); },
        hasListener(listener) { return listeners.has(listener); },
        hasListeners() { return listeners.size > 0; },
        addRules(rules, callback) { if (typeof callback === 'function') later(() => callback([])); },
        getRules(ids, callback) { const cb = typeof ids === 'function' ? ids : callback; if (typeof cb === 'function') later(() => cb([])); },
        removeRules(ids, callback) { const cb = typeof ids === 'function' ? ids : callback; if (typeof cb === 'function') later(() => cb()); },
      };
    };
    // WebKit names some features with nothing behind them: `in` isn't enough, and plain assignment can fail quietly.
    // (Where WebKit won't let the member be set, webkit-differences.js stands in for the object holding it.)
    const setMember = globalThis.__zigzagSetMember;
    let root = api;   // the object (chrome or browser) being filled now
    const put = (target, key, value, path) => {
      if (target[key] != null) return target[key];
      try { Object.defineProperty(target, key, { value, configurable: true, enumerable: true, writable: true }); } catch (e) {}
      if (target[key] == null && setMember && path) setMember(path, key, value);
      if (!path) return target[key];
      const holder = path.reduce((object, part) => object && object[part], root);
      return (holder && holder[key]) ?? target[key];
    };
    // `path` is where `target` sits under chrome, for the stand-in that's needed where WebKit refuses a member.
    const fill = (target, spec, name, path) => {
      // An MV2 extension must not see an MV3-only constant, even one webkit-differences.js already added: remove it
      // before filling (the stand-in that hides a member WebKit won't give up is the differences script's own).
      const reserved = mv3 ? null : mv3Only[name];
      if (reserved) for (const key of reserved) {
        if (!(key in target)) continue;
        try { delete target[key]; } catch (e) {}
        if (key in target && typeof globalThis.__zigzagRemoveMember === 'function') {
          try { globalThis.__zigzagRemoveMember(path || [], key); } catch (e) {}
        }
      }
      for (const fn of spec.functions || []) {
        if (!mv3 && name === 'chrome.runtime' && fn === 'getContexts') continue;
        if (typeof target[fn] !== 'function') put(target, fn, unavailable(`${name}.${fn}`), path);
      }
      for (const ev of spec.events || []) put(target, ev, event(), path);
      for (const [key, value] of Object.entries(spec.constants || {})) {
        if (reserved && reserved.has(key)) continue;
        if (target[key] === undefined) put(target, key, value, path);
      }
      for (const [key, values] of Object.entries(spec.enums || {})) {
        if (reserved && reserved.has(key)) continue;
        if (target[key] === undefined) put(target, key, Object.freeze({ ...values }), path);
      }
      for (const [key, inner] of Object.entries(spec.objects || {})) {
        const object = put(target, key, {}, path);
        if (!object || typeof object !== 'object') continue;
        if (inner.properties) for (const [prop, members] of Object.entries(inner.properties)) {
          const child = put(object, prop, {}, path && [...path, key]);
          if (child && typeof child === 'object') fill(child, members, `${name}.${key}.${prop}`, path && [...path, key, prop]);
        } else fill(object, inner, `${name}.${key}`, path && [...path, key]);
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
        // DevTools pages only, and those get their own from WebKit. userScripts stays missing unless the bridge made it
        // (it needs WebKit's scripting), as Chrome leaves it missing until it's allowed: extensions check for it and take
        // another way, and a stand-in that does nothing would send them down this one.
        // publicSuffix answers at once in Chrome, not with a promise: a stand-in's rejected promise, taken as the
        // answer, would be a site's domain to its callers. Missing, they use their own list (Tampermonkey's beta does).
        if (path.startsWith('devtools.') || (path === 'userScripts' && !target.userScripts) || path === 'publicSuffix' || !available(spec)) continue;
        let namespace = target;
        const parts = path.split('.');
        root = target;
        parts.forEach((part, index) => { namespace = namespace && put(namespace, part, {}, parts.slice(0, index)); });
        if (namespace && typeof namespace === 'object') fill(namespace, spec, `chrome.${path}`, parts);
      }
    }
    // Answers for what's now there but Zigzag can't do (webkit-differences.js).
    if (typeof globalThis.__zigzagAfterSurface === 'function') { try { globalThis.__zigzagAfterSurface(); } catch (e) {} }
    return true;
  };
  if (!start()) {
    let tries = 0;
    const again = () => { if (!start() && ++tries < 100) setTimeout(again, 20); };
    setTimeout(again, 0);
  }
})();
