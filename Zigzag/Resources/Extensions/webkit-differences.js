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

    // Sets api.<path>.<key>. WebKit declares some members of its own objects with nothing behind them and won't let
    // them be replaced; then the object holding them is stood in for by one that answers with the new member and
    // passes everything else to WebKit's (its methods still called on WebKit's object). Shared with api-surface.js.
    const extras = new WeakMap();   // stand-in -> the members it adds
    const bound = new WeakMap();    // WebKit's function -> it, bound to its object
    // WebKit keeps chrome and browser apart; an extension may use either (webextension-polyfill takes browser).
    const roots = [...new Set([globalThis.chrome, globalThis.browser])].filter(Boolean);
    const setMember = (path, key, value) => roots.map((root) => setMemberIn(root, path, key, value)).some(Boolean);
    const setMemberIn = (root, path, key, value) => {
      const parent = path.reduce((object, part) => object && object[part], root);
      if (!parent || (typeof parent !== 'object' && typeof parent !== 'function')) return false;
      const added = extras.get(parent);
      if (added) { added[key] = value; return true; }
      try { Object.defineProperty(parent, key, { value, configurable: true, writable: true, enumerable: true }); } catch (e) {}
      if (parent[key] === value) return true;
      if (!path.length) return false;
      const own = { [key]: value };
      const standIn = new Proxy(parent, {
        get(target, name) {
          if (Object.prototype.hasOwnProperty.call(own, name)) return own[name];
          const member = Reflect.get(target, name);
          if (typeof member !== 'function') return member;
          if (!bound.has(member)) bound.set(member, member.bind(target));
          return bound.get(member);
        },
        has(target, name) { return Object.prototype.hasOwnProperty.call(own, name) || name in target; },
      });
      extras.set(standIn, own);
      return setMemberIn(root, path.slice(0, -1), path[path.length - 1], standIn);
    };
    Object.defineProperty(globalThis, '__zigzagSetMember', { value: setMember, configurable: true });

    // webRequest: WebKit refuses a whole listener when its filter names a resource type it doesn't know ("webbundle")
    // or an address it won't match ("ws://*/*"), and the extension's blocking stops there (AdBlock, Adblock Plus).
    // Chrome would watch the rest: the unknown part is left out and the listener added.
    const webRequest = api.webRequest;
    if (webRequest) {
      for (const name of Object.keys(webRequest)) {
        const event = webRequest[name];
        if (!event || typeof event.addListener !== 'function') continue;
        const add = event.addListener.bind(event);
        const narrowed = (filter, text) => {
          let match = /'(\w+)' is an unknown resource type/.exec(text);
          if (match && Array.isArray(filter.types)) return { ...filter, types: filter.types.filter((type) => type !== match[1]) };
          match = /'([^']+)' is an invalid match pattern/.exec(text);
          if (match && Array.isArray(filter.urls)) return { ...filter, urls: filter.urls.filter((url) => url !== match[1]) };
          return null;
        };
        try {
          setMember(['webRequest', name], 'addListener', (listener, filter, ...rest) => {
            for (let tries = 0; ; tries++) {
              try { return add(listener, filter, ...rest); } catch (error) {
                const next = filter && tries < 30 ? narrowed(filter, String(error && error.message)) : null;
                if (!next) throw error;
                // Nothing left to watch: there's nothing for the listener to hear.
                if ((Array.isArray(next.urls) && !next.urls.length) || (Array.isArray(next.types) && !next.types.length)) return undefined;
                filter = next;
              }
            }
          });
        } catch (e) {}
      }
    }

    // cookies.onChanged: WebKit sometimes calls listeners with nothing, where Chrome always says which cookie changed
    // and why; extensions read it straight away (Grammarly). Those calls are passed over.
    const changed = api.cookies && api.cookies.onChanged;
    if (changed && typeof changed.addListener === 'function') {
      const add = changed.addListener.bind(changed);
      const remove = changed.removeListener && changed.removeListener.bind(changed);
      const has = changed.hasListener && changed.hasListener.bind(changed);
      const guarded = new WeakMap();
      setMember(['cookies', 'onChanged'], 'addListener', (listener) => {
        if (typeof listener !== 'function') return add(listener);
        const wrapped = (info, ...rest) => { if (info && info.cookie) return listener(info, ...rest); };
        guarded.set(listener, wrapped);
        return add(wrapped);
      });
      if (remove) setMember(['cookies', 'onChanged'], 'removeListener', (listener) => remove(guarded.get(listener) || listener));
      if (has) setMember(['cookies', 'onChanged'], 'hasListener', (listener) => has(guarded.get(listener) || listener));
    }

    // webRequest.handlerBehaviorChanged: in Chrome it only empties a cache so changed listeners apply at once. WebKit
    // keeps no such cache, so there's nothing to do; refused, it left an unhandled error in Tampermonkey's start.
    if (webRequest && typeof webRequest.handlerBehaviorChanged !== 'function') {
      setMember(['webRequest'], 'handlerBehaviorChanged', (callback) => {
        if (typeof callback === 'function') { setTimeout(() => callback(), 0); return undefined; }
        return Promise.resolve();
      });
    }

    // runtime.requestUpdateCheck: Zigzag updates extensions itself; as in Chrome when none is waiting, "no update".
    if (typeof api.runtime.requestUpdateCheck !== 'function') {
      setMember(['runtime'], 'requestUpdateCheck', (callback) => {
        if (typeof callback === 'function') { setTimeout(() => callback('no_update', {}), 0); return undefined; }
        return Promise.resolve({ status: 'no_update' });
      });
    }
    // Settings and address-bar keywords Zigzag doesn't have answer as Chrome answers for one an extension can't change:
    // its value, and "not_controllable", rather than an error that stops the extension (Privacy Badger, 1Password).
    const settled = (value) => (...args) => {
      const callback = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
      if (callback) { setTimeout(() => callback(value), 0); return undefined; }
      return Promise.resolve(value);
    };
    const defaults = { webRTCIPHandlingPolicy: 'default', networkPredictionEnabled: true, hyperlinkAuditingEnabled: true,
      referrersEnabled: true, doNotTrackEnabled: false, thirdPartyCookiesAllowed: true, alternateErrorPagesEnabled: false,
      safeBrowsingEnabled: true, searchSuggestEnabled: true, spellingServiceEnabled: false, translationServiceEnabled: false };
    // privacy and omnibox are WebKit-less namespaces the API surface adds, so these answers go on after it has.
    const afterSurface = () => {
    if (api.privacy) {
      for (const group of Object.keys(api.privacy)) {
        const settings = api.privacy[group];
        if (!settings || typeof settings !== 'object') continue;
        for (const name of Object.keys(settings)) {
          const setting = settings[name];
          if (!setting || typeof setting !== 'object') continue;
          const value = name in defaults ? defaults[name] : false;
          if (typeof setting.get !== 'function' || /isn't available/.test(String(setting.get))) setMember(['privacy', group, name], 'get', settled({ value, levelOfControl: 'not_controllable' }));
          for (const fn of ['set', 'clear']) setMember(['privacy', group, name], fn, settled(undefined));
        }
      }
    }
    if (api.omnibox) {
      for (const fn of ['setDefaultSuggestion']) setMember(['omnibox'], fn, settled(undefined));
    }
    };
    Object.defineProperty(globalThis, '__zigzagAfterSurface', { value: afterSurface, configurable: true });

    // declarativeNetRequest: what WebKit can't count or switch off rule by rule, answered as Chrome does when
    // nothing's been switched off (ad blockers ask as they start).
    const dnr = api.declarativeNetRequest;
    if (dnr) {
      const answer = (value) => (...args) => {
        const callback = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
        if (callback) { setTimeout(() => callback(value), 0); return undefined; }
        return Promise.resolve(value);
      };
      if (typeof dnr.getAvailableStaticRuleCount !== 'function') setMember(['declarativeNetRequest'], 'getAvailableStaticRuleCount', answer(dnr.GUARANTEED_MINIMUM_STATIC_RULES || 30000));
      if (typeof dnr.getDisabledRuleIds !== 'function') setMember(['declarativeNetRequest'], 'getDisabledRuleIds', answer([]));
      // Switching off single built-in rules (an ad blocker's exceptions) isn't something WebKit does: the call goes
      // through, and the rule sets stay as they were, rather than the extension stopping on it.
      if (typeof dnr.updateStaticRules !== 'function') setMember(['declarativeNetRequest'], 'updateStaticRules', answer(undefined));
      // WebKit takes regular expressions in rules but answers the question with nothing (DuckDuckGo asks first).
      const isRegexSupported = typeof dnr.isRegexSupported === 'function' ? dnr.isRegexSupported.bind(dnr) : null;
      setMember(['declarativeNetRequest'], 'isRegexSupported', (options, callback) => {
        const result = Promise.resolve(isRegexSupported ? isRegexSupported(options) : undefined).catch(() => undefined)
          .then((answer) => (answer && typeof answer.isSupported === 'boolean' ? answer : { isSupported: true }));
        if (typeof callback !== 'function') return result;
        result.then(callback);
        return undefined;
      });
    }
    return true;
  };
  if (!start()) {
    let tries = 0;
    const again = () => { if (!start() && ++tries < 100) setTimeout(again, 20); };
    setTimeout(again, 0);
  }
})();
