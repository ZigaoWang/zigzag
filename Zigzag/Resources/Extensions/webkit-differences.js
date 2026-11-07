// Where WebKit's extension APIs answer differently from Chrome's, made to answer as Chrome does.
//
// Runs after the bridge and the compatibility layer and before the API surface (api-surface.js), in an extension's
// background and pages. Each fix is for something seen stopping real extensions; each leaves alone anything that
// already behaves.
(() => {
  const start = () => {
    const api = globalThis.chrome || globalThis.browser;
    if (globalThis.__zigzagDifferences) return true;
    if (!api || !api.runtime) return false;
    globalThis.__zigzagDifferences = true;

    // webRequest: WebKit refuses a whole listener when its filter names a resource type it doesn't know ("webbundle")
    // or an address it won't match ("ws://*/*"), and the extension's blocking stops there (AdBlock, Adblock Plus).
    // Chrome would watch the rest: the unknown part is left out and the listener added.
    const webRequest = api.webRequest;
    if (webRequest) {
      for (const name of Object.keys(webRequest)) {
        const event = webRequest[name];
        if (!event || typeof event.addListener !== 'function' || event.__zigzagFiltered) continue;
        const add = event.addListener.bind(event);
        const narrowed = (filter, text) => {
          let match = /'(\w+)' is an unknown resource type/.exec(text);
          if (match && Array.isArray(filter.types)) return { ...filter, types: filter.types.filter((type) => type !== match[1]) };
          match = /'([^']+)' is an invalid match pattern/.exec(text);
          if (match && Array.isArray(filter.urls)) return { ...filter, urls: filter.urls.filter((url) => url !== match[1]) };
          return null;
        };
        try {
          Object.defineProperty(event, 'addListener', { configurable: true, writable: true, value: (listener, filter, ...rest) => {
            for (let tries = 0; ; tries++) {
              try { return add(listener, filter, ...rest); } catch (error) {
                const next = filter && tries < 30 ? narrowed(filter, String(error && error.message)) : null;
                if (!next) throw error;
                // Nothing left to watch: there's nothing for the listener to hear.
                if ((Array.isArray(next.urls) && !next.urls.length) || (Array.isArray(next.types) && !next.types.length)) return undefined;
                filter = next;
              }
            }
          } });
          Object.defineProperty(event, '__zigzagFiltered', { value: true });
        } catch (e) {}
      }
    }

    // cookies.onChanged: WebKit sometimes calls listeners with nothing, where Chrome always says which cookie changed
    // and why; extensions read it straight away (Grammarly). Those calls are passed over.
    const changed = api.cookies && api.cookies.onChanged;
    if (changed && typeof changed.addListener === 'function' && !changed.__zigzagGuarded) {
      const add = changed.addListener.bind(changed);
      const remove = changed.removeListener && changed.removeListener.bind(changed);
      const has = changed.hasListener && changed.hasListener.bind(changed);
      const guarded = new WeakMap();
      try {
        changed.addListener = (listener) => {
          if (typeof listener !== 'function') return add(listener);
          const wrapped = (info, ...rest) => { if (info && info.cookie) return listener(info, ...rest); };
          guarded.set(listener, wrapped);
          return add(wrapped);
        };
        if (remove) changed.removeListener = (listener) => remove(guarded.get(listener) || listener);
        if (has) changed.hasListener = (listener) => has(guarded.get(listener) || listener);
        Object.defineProperty(changed, '__zigzagGuarded', { value: true });
      } catch (e) {}
    }

    // runtime.requestUpdateCheck: Zigzag updates extensions itself; as in Chrome when none is waiting, "no update".
    if (typeof api.runtime.requestUpdateCheck !== 'function') {
      try {
        api.runtime.requestUpdateCheck = (callback) => {
          const answer = { status: 'no_update' };
          if (typeof callback === 'function') { setTimeout(() => callback('no_update', {}), 0); return undefined; }
          return Promise.resolve(answer);
        };
      } catch (e) {}
    }
    return true;
  };
  if (!start()) {
    let tries = 0;
    const again = () => { if (!start() && ++tries < 100) setTimeout(again, 20); };
    setTimeout(again, 0);
  }
})();
