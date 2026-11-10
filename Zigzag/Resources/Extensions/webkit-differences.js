// Where WebKit's extension APIs answer differently from Chrome's, made to answer as Chrome does.
//
// Runs after the bridge and the compatibility layer and before the API surface (api-surface.js), in an extension's
// background and pages. Each fix is for something seen stopping real extensions; each leaves alone anything that
// already behaves.
(() => {
  // Explicit resource management (`using`): Chrome has Symbol.dispose and Symbol.asyncDispose, this WebKit doesn't
  // yet. Code compiled for it checks they exist and stops with "Symbol.dispose is not defined." (Bitwarden, as you
  // sign in). They're well-known symbols, so one of each is all that code needs; registered ones, so any other copy
  // of this answer, in another page or a library's own, is the same symbol.
  for (const name of ['dispose', 'asyncDispose']) {
    if (typeof Symbol[name] !== 'symbol') {
      try { Object.defineProperty(Symbol, name, { value: Symbol.for(`Symbol.${name}`) }); } catch (e) {}
    }
  }

  const isWorker = typeof ServiceWorkerGlobalScope !== 'undefined' && globalThis instanceof ServiceWorkerGlobalScope;

  // importScripts: WebKit hands the worker its events while a load is under way (between one script and the next),
  // which Chrome never does, and a worker that's starting can get messages before its install event. Rabby, like the
  // other MetaMask-style wallets, loads its scripts on install or on the first message, whichever comes first. After a
  // relaunch its restored pages message it first: that load began, install and activate ran inside it, and its main
  // script, reached after them, was refused (WebKit loads new scripts only while installing), so its popup said "Rabby
  // failed to start". Install's own load, inside the other, ran its code a second time as well. So install waits for
  // a load under way to finish, and a load from inside another leaves out the scripts that one is loading; they still
  // run, once, as it goes on.
  if (isWorker && typeof globalThis.importScripts === 'function') {
    const load = globalThis.importScripts;
    const loading = [];
    let loaded = null;
    const address = (url) => { try { return new URL(String(url), location.href).href; } catch (e) { return String(url); } };
    const importScripts = function importScripts(...urls) {
      const fresh = urls.filter((url) => !loading.includes(address(url)));
      if (urls.length && !fresh.length) return undefined;
      const mine = fresh.map(address);
      loading.push(...mine);
      try {
        return load.apply(globalThis, fresh);
      } finally {
        loading.splice(loading.length - mine.length, mine.length);
        if (!loading.length && loaded) { loaded(); loaded = null; }
      }
    };
    try { Object.defineProperty(globalThis, 'importScripts', { value: importScripts, configurable: true, writable: true }); } catch (e) {}
    // Added before the extension's own install listeners, so the wait covers theirs too.
    if (typeof globalThis.addEventListener === 'function') {
      globalThis.addEventListener('install', (event) => {
        if (loading.length && !loaded) event.waitUntil(new Promise((resolve) => { loaded = resolve; }));
      });
    }
  }

  // An extension's pages and its background service worker posting to each other (navigator.serviceWorker and the
  // worker's clients): in Chrome the worker controls its extension's pages and they reach it, in WebKit nothing the
  // pages post arrives, and the worker's clients don't include them. Violentmonkey's popup and dashboard ask its
  // background for everything that way, so its buttons did nothing and its dashboard stayed blank. Here it travels
  // over a runtime port instead: the page connects when it first posts to its worker (or when a worker that relies on
  // this looks for its clients), and each end sees the other's messages as message events, as in Chrome. Pages and
  // workers that never use it are left exactly as WebKit has them.
  const WORKER_PORT = '__zigzagWorkerClient';
  const TAB_PORT = '__zigzagTabPage';
  // What can travel over a port: Chrome would carry an Error across, so its name and message go along.
  const portable = (value) => {
    try { return JSON.parse(JSON.stringify(value, (key, v) => (v instanceof Error ? { name: v.name, message: v.message, stack: v.stack } : v))); } catch (e) { return value; }
  };
  // Between a page and its worker Chrome copies bytes too (a file's, to upload); a runtime port carries only JSON,
  // so they go as base64 and come out as what they were.
  const BYTES_KEY = '__zigzagBytes';
  const carried = (value) => {
    try {
      return JSON.parse(JSON.stringify(value, (key, v) => {
        if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) {
          const bytes = v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
          let text = '';
          for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          return { [BYTES_KEY]: btoa(text), type: v instanceof ArrayBuffer ? 'ArrayBuffer' : v.constructor.name };
        }
        return v instanceof Error ? { name: v.name, message: v.message, stack: v.stack } : v;
      }));
    } catch (e) { return value; }
  };
  // Only these come back as what they were. What a site posts on a port reaches the worker this way too, and its
  // `type` must never name some other constructor of the worker's to call.
  const VIEWS = new Set(['DataView', 'Int8Array', 'Uint8Array', 'Uint8ClampedArray', 'Int16Array', 'Uint16Array', 'Int32Array',
    'Uint32Array', 'Float16Array', 'Float32Array', 'Float64Array', 'BigInt64Array', 'BigUint64Array']);
  const restored = (value) => {
    if (!value || typeof value !== 'object') return value;
    if (typeof value[BYTES_KEY] === 'string') {
      let text = '';
      try { text = atob(value[BYTES_KEY]); } catch (e) {}
      const bytes = new Uint8Array(text.length);
      for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
      const View = VIEWS.has(value.type) ? globalThis[value.type] : null;
      if (typeof View !== 'function' || (View.BYTES_PER_ELEMENT && bytes.length % View.BYTES_PER_ELEMENT)) return bytes.buffer;
      return View === DataView ? new DataView(bytes.buffer) : new View(bytes.buffer, 0, bytes.length / View.BYTES_PER_ELEMENT);
    }
    for (const key of Object.keys(value)) value[key] = restored(value[key]);
    return value;
  };
  const workerPage = (() => {
    if (isWorker || typeof location === 'undefined' || location.protocol !== 'webkit-extension:') return null;
    const container = globalThis.navigator && navigator.serviceWorker;
    if (!container || typeof ServiceWorker === 'undefined') return null;
    const own = location.origin + '/';
    let port = null;
    // The worker the page posted to, as its messages' source.
    let worker = null;
    // MessageChannel ports the page handed its worker, by number: what the worker posts on one arrives here, and
    // what's posted to this end goes to the worker's.
    const handed = new Map();
    let handedCount = 0;
    const connect = () => {
      if (port) return port;
      const api = globalThis.chrome || globalThis.browser;
      const current = port = api.runtime.connect({ name: WORKER_PORT });
      current.onMessage.addListener((message) => {
        if (!message) return;
        if (message.kind === 'port') {
          const relay = handed.get(message.id);
          if (relay) relay.end.postMessage(restored(message.data));
          return;
        }
        if (message.kind !== 'message') return;
        const event = new MessageEvent('message', { data: restored(message.data), origin: location.origin });
        Object.defineProperty(event, 'source', { value: container.controller || worker });
        container.dispatchEvent(event);
      });
      // The worker was unloaded: the next message wakes it, over a new port. The ports handed to it are gone with it.
      current.onDisconnect.addListener(() => {
        if (port === current) port = null;
        for (const [id, relay] of handed) {
          if (relay.over !== current) continue;
          handed.delete(id);
          try { relay.end.close(); } catch (e) {}
        }
      });
      return current;
    };
    const send = (message, transfer) => {
      const over = connect();
      const list = Array.isArray(transfer) ? transfer : (transfer && transfer.transfer) || [];
      const ports = [];
      for (const end of list) {
        if (typeof MessagePort === 'undefined' || !(end instanceof MessagePort)) continue;
        const id = ++handedCount;
        handed.set(id, { end, over });
        end.onmessage = (event) => { try { over.postMessage({ kind: 'port', id, data: carried(event.data) }); } catch (e) {} };
        ports.push(id);
      }
      over.postMessage({ kind: 'message', data: carried(message), ports });
    };
    // controller stays WebKit's (none): Violentmonkey then posts to navigator.serviceWorker.ready's active worker,
    // which WebKit does give, and only those posts, to the extension's own worker, go over the port. A Message-
    // Channel's ports handed over with a post go too, each end relayed over the port (Kondo's site reaches its worker
    // through one).
    try {
      const post = ServiceWorker.prototype.postMessage;
      ServiceWorker.prototype.postMessage = function (message, ...rest) {
        let url = '';
        try { url = String(this.scriptURL); } catch (e) {}
        if (!url.startsWith(own)) return post.call(this, message, ...rest);
        worker = this;
        return send(message, rest[0]);
      };
    } catch (e) { return null; }
    // An extension page in a tab, or in a frame on a site, has no worker in WebKit (navigator.serviceWorker.ready
    // never settles), where Chrome gives every page of the extension its worker. Kondo's frame on its site waited
    // there for good, so the site never reached the extension. When WebKit has none for the page, ready gives one
    // that stands for the extension's worker; its posts take the port above.
    try {
      const ready = Object.getOwnPropertyDescriptor(ServiceWorkerContainer.prototype, 'ready');
      let standIn = null;
      if (ready && ready.get) {
        Object.defineProperty(container, 'ready', { configurable: true, get() {
          if (standIn) return standIn;
          const native = ready.get.call(container);
          const api = globalThis.chrome || globalThis.browser;
          let script = null;
          try { script = ((api.runtime.getManifest() || {}).background || {}).service_worker; } catch (e) {}
          if (!script) return native;
          standIn = container.getRegistration().then((registration) => {
            if (registration) return native;
            const active = Object.create(ServiceWorker.prototype, {
              scriptURL: { value: own + String(script).replace(/^\//, '') }, state: { value: 'activated' },
              onstatechange: { value: null, writable: true }, onerror: { value: null, writable: true },
            });
            return Object.create(ServiceWorkerRegistration.prototype, {
              active: { value: active }, installing: { value: null }, waiting: { value: null }, scope: { value: own },
              update: { value: () => Promise.resolve() }, unregister: { value: () => Promise.resolve(false) },
            });
          }, () => native);
          return standIn;
        } });
      }
    } catch (e) {}
    return { connect };
  })();

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
    // WebKit keeps its API objects only while something else does, and makes new ones, without what was set on them,
    // when asked again after they're gone, so a fix could miss the extension's later calls (Bitwarden's background, on
    // some starts). Each object a member is set on, and the ones leading to it, are kept here.
    const kept = new Set();
    const setMemberIn = (root, path, key, value) => {
      const parent = path.reduce((object, part) => { kept.add(object); return object && object[part]; }, root);
      kept.add(parent);
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

    // A page asked to connect to its worker (below), when the worker looks for its clients.
    if (workerPage && api.runtime.onMessage && typeof api.runtime.onMessage.addListener === 'function') {
      api.runtime.onMessage.addListener((message) => { if (message && message[WORKER_PORT] === 'connect') workerPage.connect(); });
    }

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
        // A filter with only main_frame hears nothing in WebKit, and one with only sub_frame hears main frames too.
        // Violentmonkey watches main_frame for .user.js loads, so opening a script's address never opened its install
        // page. WebKit is asked for both, and the listener hears only the kinds it named, as in Chrome.
        const remove = event.removeListener && event.removeListener.bind(event);
        const has = event.hasListener && event.hasListener.bind(event);
        const sorted = new WeakMap();
        const frames = (listener, filter) => {
          const types = filter && Array.isArray(filter.types) ? filter.types : null;
          if (typeof listener !== 'function' || !types || !types.some((type) => type === 'main_frame' || type === 'sub_frame')) return null;
          if (!sorted.has(listener)) {
            const wanted = new Set();
            const heard = (details, ...more) => { if (!details || wanted.has(details.type)) return listener(details, ...more); };
            sorted.set(listener, Object.assign(heard, { wanted }));
          }
          const heard = sorted.get(listener);
          types.forEach((type) => heard.wanted.add(type));
          return { listener: heard, filter: { ...filter, types: [...new Set([...types, 'main_frame', 'sub_frame'])] } };
        };
        try {
          if (remove) setMember(['webRequest', name], 'removeListener', (listener) => {
            const heard = sorted.get(listener);
            sorted.delete(listener);
            return remove(heard || listener);
          });
          if (has) setMember(['webRequest', name], 'hasListener', (listener) => has(sorted.get(listener) || listener));
        } catch (e) {}
        try {
          setMember(['webRequest', name], 'addListener', (listener, filter, ...rest) => {
            const framed = frames(listener, filter);
            if (framed) ({ listener, filter } = framed);
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

    // cookies.onChanged: WebKit calls listeners with nothing, where Chrome says which cookie changed and why, and
    // extensions read it straight away (Grammarly). Kondo waits for LinkedIn's sign-in cookie to arrive, so adding an
    // account never finished. Here the extension's cookies are looked at again on each call, and its listeners hear
    // what's different from the last look, one cookie at a time, as from Chrome. A call that does say is passed on.
    const changed = api.cookies && api.cookies.onChanged;
    const allCookies = api.cookies && typeof api.cookies.getAll === 'function' ? api.cookies.getAll.bind(api.cookies) : null;
    if (changed && typeof changed.addListener === 'function') {
      const add = changed.addListener.bind(changed);
      const listeners = new Set();
      const tell = (info) => { for (const listener of [...listeners]) { try { listener(info); } catch (e) { console.error(e); } } };
      const key = (cookie) => [cookie.storeId, cookie.domain, cookie.path, cookie.name].join('\u0001');
      // The cookies at the last look, by Chrome's way of telling one from another.
      let seen = null;
      let looking = false;
      let again = false;
      const look = () => {
        if (looking) { again = true; return; }
        looking = true;
        Promise.resolve(allCookies ? allCookies({}) : []).then((list) => {
          const now = new Map((list || []).map((cookie) => [key(cookie), cookie]));
          const before = seen;
          seen = now;
          if (!before) return;
          for (const [id, cookie] of before) {
            const after = now.get(id);
            if (!after) {
              const expired = typeof cookie.expirationDate === 'number' && cookie.expirationDate * 1000 <= Date.now();
              tell({ removed: true, cookie, cause: expired ? 'expired' : 'explicit' });
            } else if (JSON.stringify(after) !== JSON.stringify(cookie)) {
              tell({ removed: true, cookie, cause: 'overwrite' });
              tell({ removed: false, cookie: after, cause: 'explicit' });
            }
          }
          for (const [id, cookie] of now) if (!before.has(id)) tell({ removed: false, cookie, cause: 'explicit' });
        }, () => {}).finally(() => {
          looking = false;
          if (again) { again = false; look(); }
        });
      };
      let watching = false;
      setMember(['cookies', 'onChanged'], 'addListener', (listener) => {
        if (typeof listener !== 'function') return add(listener);
        listeners.add(listener);
        if (watching) return undefined;
        // One listener of WebKit's for all of the extension's; the first look is what later ones are compared with.
        watching = true;
        look();
        return add((info) => { if (info && info.cookie) tell(info); else look(); });
      });
      setMember(['cookies', 'onChanged'], 'removeListener', (listener) => { listeners.delete(listener); });
      setMember(['cookies', 'onChanged'], 'hasListener', (listener) => listeners.has(listener));
    }

    // cookies: a cookie as Chrome described it can name Chrome's everyday store, "0", and a SameSite of "unspecified";
    // WebKit's store has its own name, and it refuses both, so the cookie isn't set. Kondo puts back a LinkedIn
    // sign-in it saved that way. Both mean what no storeId and no sameSite mean, so they're left out.
    const cookies = api.cookies;
    if (cookies) {
      for (const name of ['get', 'getAll', 'set', 'remove']) {
        if (typeof cookies[name] !== 'function') continue;
        const native = cookies[name].bind(cookies);
        setMember(['cookies'], name, (details, ...rest) => {
          if (!details || typeof details !== 'object' || (details.storeId !== '0' && details.sameSite !== 'unspecified')) return native(details, ...rest);
          const own = { ...details };
          if (own.storeId === '0') delete own.storeId;
          if (own.sameSite === 'unspecified') delete own.sameSite;
          return native(own, ...rest);
        });
      }
    }

    // action.setIcon: WebKit refuses details that give both imageData and path, where Chrome takes imageData and
    // passes over path. Violentmonkey gives both each time it marks a tab, so its button's icon never changed.
    for (const name of ['action', 'browserAction']) {
      const action = api[name];
      if (!action || typeof action.setIcon !== 'function') continue;
      const setIcon = action.setIcon.bind(action);
      setMember([name], 'setIcon', (details, ...rest) => {
        if (details && typeof details === 'object' && details.imageData != null && details.path != null) {
          const images = typeof details.imageData === 'object' && !(ArrayBuffer.isView(details.imageData) || 'data' in details.imageData)
            ? Object.values(details.imageData).some((image) => image != null) : true;
          const { path, imageData, ...others } = details;
          details = images ? { ...others, imageData } : { ...others, path };
        }
        return setIcon(details, ...rest);
      });
    }

    // permissions.contains: WebKit refuses the whole question, and throws, when it names a permission WebKit doesn't
    // know ("downloads"), where Chrome answers. Violentmonkey asks about "downloads" on its background's first line,
    // so its background stopped there. Such a permission counts as held when the extension's manifest asks for it
    // outright (Zigzag's bridge answers for those), and not otherwise; the rest is still WebKit's to answer.
    const permissions = api.permissions;
    if (permissions && typeof permissions.contains === 'function') {
      const contains = permissions.contains.bind(permissions);
      let required = [];
      try { required = api.runtime.getManifest().permissions || []; } catch (e) {}
      setMember(['permissions'], 'contains', (asked, callback) => {
        const answer = (async () => {
          let query = Object.assign({}, asked);
          let held = true;
          for (let tries = 0; ; tries++) {
            try { return held && await contains(query); } catch (error) {
              // An origin with a port ("http://127.0.0.1:8777/*"), which Chrome reads and WebKit refuses: asked
              // without it, as a pattern without a port covers every port. 1Password asks so on local sites.
              const pattern = /'([^']+)' is not a valid pattern/.exec(String(error && error.message));
              const portless = pattern && pattern[1].replace(/^([a-z*]+:\/\/[^/:]+):(\d+|\*)(?=\/)/, '$1');
              if (portless && portless !== pattern[1] && tries <= 30 && Array.isArray(query.origins)) {
                query = Object.assign({}, query, { origins: query.origins.map((origin) => (origin === pattern[1] ? portless : origin)) });
                continue;
              }
              const unknown = /'([^']+)' is not a valid permission/.exec(String(error && error.message));
              if (!unknown || tries > 30 || !Array.isArray(query.permissions)) throw error;
              held = held && required.includes(unknown[1]);
              query = Object.assign({}, query, { permissions: query.permissions.filter((name) => name !== unknown[1]) });
            }
          }
        })();
        if (typeof callback !== 'function') return answer;
        answer.then((value) => callback(value), () => callback(false));
      });
    }

    // runtime.sendMessage's answer: WebKit cuts a string in the answer short at its first NUL character, which Chrome
    // carries whole; the message itself and port messages arrive whole. Tampermonkey's dashboard gets site icons from
    // its background as binary strings, so each arrived as "PNG" and showed a question mark. Between the extension's
    // own pages and background (both run this), such an answer travels as JSON, which writes NUL as text, and is
    // read back on arrival. Content scripts don't run this, so what they're sent stays as WebKit carries it.
    const ownPages = (() => { try { return api.runtime.getURL(''); } catch (e) { return null; } })();
    const NUL_KEY = '__zigzagWithNul';
    const withNul = (value) => {
      if (value == null || (typeof value !== 'object' && typeof value !== 'string')) return value;
      let text;
      try { text = JSON.stringify(value); } catch (e) { return value; }
      return text && text.includes('\\u0000') ? { [NUL_KEY]: text } : value;
    };
    const unwrapNul = (value) => (value && typeof value === 'object' && typeof value[NUL_KEY] === 'string' ? JSON.parse(value[NUL_KEY]) : value);
    const onMessage = api.runtime.onMessage;
    // The extension's own runtime.onMessage listeners on this page, for messages sent to its tab (below).
    const heard = new Set();
    let tabPage = null;
    if (ownPages && onMessage && typeof onMessage.addListener === 'function') {
      const add = onMessage.addListener.bind(onMessage);
      const remove = onMessage.removeListener && onMessage.removeListener.bind(onMessage);
      const has = onMessage.hasListener && onMessage.hasListener.bind(onMessage);
      const answering = new WeakMap();
      setMember(['runtime', 'onMessage'], 'addListener', (listener) => {
        if (typeof listener !== 'function') return add(listener);
        const wrapped = (message, sender, sendResponse) => {
          if (message && message[WORKER_PORT]) return undefined;
          if (!sender || typeof sender.url !== 'string' || !sender.url.startsWith(ownPages)) return listener(message, sender, sendResponse);
          const result = listener(message, sender, (value) => sendResponse(withNul(value)));
          return result && typeof result.then === 'function' ? result.then(withNul) : result;
        };
        answering.set(listener, wrapped);
        heard.add(listener);
        if (tabPage) tabPage.listening();
        return add(wrapped);
      });
      if (remove) {
        setMember(['runtime', 'onMessage'], 'removeListener', (listener) => {
          heard.delete(listener);
          if (tabPage) tabPage.listening();
          return remove(answering.get(listener) || listener);
        });
      }
      if (has) setMember(['runtime', 'onMessage'], 'hasListener', (listener) => has(answering.get(listener) || listener));
    }
    if (ownPages && typeof api.runtime.sendMessage === 'function') {
      const sendMessage = api.runtime.sendMessage.bind(api.runtime);
      setMember(['runtime'], 'sendMessage', (...args) => {
        const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        if (callback) return sendMessage(...args, (value) => callback(unwrapNul(value)));
        const sent = sendMessage(...args);
        return sent && typeof sent.then === 'function' ? sent.then(unwrapNul) : sent;
      });
    }

    // tabs.sendMessage: Chrome delivers it to the extension's own pages inside that tab too (a frame of its own page
    // on a site), WebKit only to its content scripts. 1Password's sign-in banner on a site is such a frame, told to
    // close that way once you've signed in, so it stayed on the page. Each such page that listens for messages
    // keeps a port to its background, which hands it what's sent to its tab and carries its answer back.
    const background = isWorker || (() => { try { return !!api.extension && api.extension.getBackgroundPage() === globalThis; } catch (e) { return false; } })();
    if (!background && ownPages && typeof api.runtime.connect === 'function') {
      let port = null;
      let quickDrops = 0;
      let inTab = true;
      const connect = () => {
        if (port || !heard.size || !inTab) return;
        let opened = Date.now();
        try { port = api.runtime.connect({ name: TAB_PORT }); } catch (e) { port = null; return; }
        port.onMessage.addListener((message) => {
          // Not in a tab (a popup): nothing is sent its way.
          if (message && message.kind === 'no-tab') inTab = false;
          if (!message || message.kind !== 'tab-message') return;
          const own = port;
          let answered = false;
          const sendResponse = (value) => {
            if (answered) return;
            answered = true;
            try { own.postMessage({ kind: 'tab-answer', id: message.id, value: portable(value) }); } catch (e) {}
          };
          let waits = false;
          for (const listener of [...heard]) {
            let result;
            try { result = listener(message.message, message.sender, sendResponse); } catch (e) { continue; }
            if (result === true) waits = true;
            else if (result && typeof result.then === 'function') { waits = true; result.then(sendResponse, () => {}); }
          }
          if (!waits && !answered) { answered = true; try { own.postMessage({ kind: 'tab-answer', id: message.id, none: true }); } catch (e) {} }
        });
        port.onDisconnect.addListener(() => {
          port = null;
          // The background restarted: connect again, unless it keeps refusing.
          quickDrops = Date.now() - opened < 1000 ? quickDrops + 1 : 0;
          if (quickDrops < 3) setTimeout(connect, 500);
        });
        port.postMessage({ kind: 'listening', value: true });
      };
      tabPage = {
        listening: () => {
          if (!port) { setTimeout(connect, 0); return; }
          try { port.postMessage({ kind: 'listening', value: heard.size > 0 }); } catch (e) {}
        },
      };
      if (heard.size) tabPage.listening();
    }

    // runtime.onInstalled: WebKit says "install" each time an extension is turned back on, where Chrome says nothing.
    // Tampermonkey takes "install" to mean the scripts it already has were planted, and turns every one off. Zigzag
    // knows what it installed (BridgeRuntime): only a real install is passed on as one, a moment later.
    const installed = api.runtime.onInstalled;
    if (installed && typeof installed.addListener === 'function' && typeof api.runtime.sendNativeMessage === 'function') {
      let fresh = null;
      const isFresh = () => fresh || (fresh = Promise.resolve(api.runtime.sendNativeMessage('zigzag.bridge', { ns: 'runtime', fn: 'isNewInstall', args: [] }))
        .then((reply) => !reply || typeof reply.error === 'string' || !!reply.value, () => true));
      const add = installed.addListener.bind(installed);
      const remove = installed.removeListener && installed.removeListener.bind(installed);
      const has = installed.hasListener && installed.hasListener.bind(installed);
      const guarded = new WeakMap();
      setMember(['runtime', 'onInstalled'], 'addListener', (listener) => {
        if (typeof listener !== 'function') return add(listener);
        const wrapped = (details, ...rest) => {
          if (!details || details.reason !== 'install') return listener(details, ...rest);
          isFresh().then((yes) => { if (yes) listener(details, ...rest); });
        };
        guarded.set(listener, wrapped);
        return add(wrapped);
      });
      if (remove) setMember(['runtime', 'onInstalled'], 'removeListener', (listener) => remove(guarded.get(listener) || listener));
      if (has) setMember(['runtime', 'onInstalled'], 'hasListener', (listener) => has(guarded.get(listener) || listener));
    }

    // Content scripts an extension registers: WebKit refuses file: match patterns, and one it refuses loses the whole
    // registration, so Rabby's provider reached no site at all for the file://*/* beside its http and https. Asked as
    // written first, so nothing is lost on a WebKit that takes them. If that fails for any reason it's asked once more
    // without them, unless nothing would be left to ask for, and if that fails too the extension hears the first
    // answer, by promise or callback alike. WebKit's words aren't relied on.
    if (api.scripting && typeof api.scripting.registerContentScripts === 'function') {
      const patternKeys = ['matches', 'excludeMatches'];
      const isFile = (pattern) => String(pattern).startsWith('file:');
      const namesFiles = (script) => script && typeof script === 'object' && patternKeys.some((key) => Array.isArray(script[key]) && script[key].some(isFile));
      const withoutFiles = (script) => {
        if (!namesFiles(script)) return script;
        const copy = { ...script };
        for (const key of patternKeys) { if (Array.isArray(copy[key])) copy[key] = copy[key].filter((pattern) => !isFile(pattern)); }
        return copy;
      };
      const stillMatches = (script) => !script || typeof script !== 'object' || !Array.isArray(script.matches) || script.matches.length > 0;
      // What the second try left out: scripts that kept other patterns, and ones whose matches were all file:, skipped.
      const note = (name, scripts) => {
        const id = (script) => String(script.id);
        const named = scripts.filter(namesFiles);
        const trimmed = named.filter((script) => stillMatches(withoutFiles(script))).map(id);
        const skipped = named.filter((script) => !stillMatches(withoutFiles(script))).map(id);
        const done = name === 'updateContentScripts' ? 'updated' : 'registered';
        const text = [
          trimmed.length ? `${trimmed.join(', ')} ${done} without file: patterns` : '',
          skipped.length ? `skipped ${skipped.join(', ')}, whose matches were all file:` : '',
        ].filter(Boolean).join('; ');
        try { const sent = api.runtime.sendNativeMessage('zigzag.diagnostics', { where: 'scripting', kind: 'note', text: `${name}: ${text}` }); if (sent && sent.catch) sent.catch(() => {}); } catch (e) {}
      };
      // A callback hears a failure through runtime.lastError, as from WebKit, for as long as it runs.
      const callWithError = (callback, error) => {
        const lastError = { message: String((error && error.message) || error) };
        const runtimes = [...new Set(roots.map((root) => root.runtime))].filter(Boolean);
        const before = runtimes.map((runtime) => Object.getOwnPropertyDescriptor(runtime, 'lastError'));
        for (const runtime of runtimes) { try { Object.defineProperty(runtime, 'lastError', { get: () => lastError, configurable: true }); } catch (e) {} }
        try { callback(); } finally {
          runtimes.forEach((runtime, index) => {
            try { if (before[index]) Object.defineProperty(runtime, 'lastError', before[index]); else delete runtime.lastError; } catch (e) {}
          });
        }
      };
      for (const name of ['registerContentScripts', 'updateContentScripts']) {
        if (typeof api.scripting[name] !== 'function') continue;
        const original = api.scripting[name].bind(api.scripting);
        setMember(['scripting'], name, (scripts, ...rest) => {
          if (!Array.isArray(scripts) || !scripts.some(namesFiles)) return original(scripts, ...rest);
          const kept = scripts.map(withoutFiles).filter(stillMatches);
          const callback = rest.find((argument) => typeof argument === 'function');
          const answer = new Promise((resolve) => resolve(original(scripts))).catch((error) => {
            if (!kept.length) throw error;
            return Promise.resolve().then(() => original(kept)).then((result) => { note(name, scripts); return result; }, () => { throw error; });
          });
          if (!callback) return answer;
          answer.then(() => callback(), (error) => callWithError(callback, error));
          return undefined;
        });
      }
    }

    // Ports into a service worker background: WebKit unloads such a background 30 seconds after the last event it
    // was sent, even while a page or content script is talking to it over a port (it means to keep it for open ports,
    // but doesn't count a worker's), and doesn't tell the other end, whose port goes quiet for good. Chrome keeps a
    // worker going while its ports are in use. Bitwarden's popup reads its vault over one, so it hung on a spinner.
    // While a port into the worker is open, it asks for its background page every 20 seconds: WebKit wakes the
    // background to answer, which starts its 30 seconds over.
    const onConnect = api.runtime.onConnect;
    const connectRaw = onConnect && typeof onConnect.addListener === 'function' ? onConnect.addListener.bind(onConnect) : null;
    let keepOpen = null;
    if (isWorker && onConnect && typeof onConnect.addListener === 'function' && typeof api.runtime.getBackgroundPage === 'function') {
      const open = new Set();
      let beat = null;
      const ask = () => { try { const asked = api.runtime.getBackgroundPage(); if (asked && asked.catch) asked.catch(() => {}); } catch (e) {} };
      const settle = () => {
        if (open.size && !beat) beat = setInterval(ask, 20000);
        if (!open.size && beat) { clearInterval(beat); beat = null; }
      };
      // Only once the extension listens itself: a port nothing listens for should still end at once, as in Chrome.
      const add = onConnect.addListener.bind(onConnect);
      let watching = false;
      const watch = () => {
        if (watching) return;
        watching = true;
        add((port) => keepOpen(port));
      };
      keepOpen = (port) => {
        if (open.has(port)) return;
        open.add(port);
        port.onDisconnect.addListener(() => { open.delete(port); settle(); });
        settle();
      };
      setMember(['runtime', 'onConnect'], 'addListener', (listener) => {
        const result = add(listener);
        if (typeof listener === 'function') watch();
        return result;
      });
    }

    // The pages' way to the worker (above), at the worker's end; kept going while open, as other ports into it are.
    // The extension's own listeners never see these ports, nor the ask to connect.
    if (onConnect && typeof onConnect.addListener === 'function') {
      const add = connectRaw;
      const current = api.runtime.onConnect;
      const extensionAdd = current.addListener.bind(current);
      const remove = onConnect.removeListener && onConnect.removeListener.bind(onConnect);
      const has = onConnect.hasListener && onConnect.hasListener.bind(onConnect);
      if (isWorker) {
        const pages = new Map();
        // The worker's clients include the pages, as in Chrome (Violentmonkey finds its offscreen page so). Pages not
        // yet connected are asked to, and given a moment. Only once the extension relies on this, when a page has
        // posted to the worker or the worker has made an offscreen page: other workers keep WebKit's clients as they
        // are, with no wait.
        const workerClients = globalThis.clients;
        let relied = false;
        const rely = () => {
          if (relied || !workerClients || typeof workerClients.matchAll !== 'function') return;
          relied = true;
          const matchAll = workerClients.matchAll.bind(workerClients);
          const get = typeof workerClients.get === 'function' ? workerClients.get.bind(workerClients) : null;
          const gather = async () => {
            try { const asked = api.runtime.sendMessage({ [WORKER_PORT]: 'connect' }); if (asked && asked.catch) asked.catch(() => {}); } catch (e) {}
            await new Promise((resolve) => setTimeout(resolve, 150));
            return [...pages.values()];
          };
          try {
            Object.defineProperty(workerClients, 'matchAll', { configurable: true, writable: true, value: async (options = {}) => {
              const real = await matchAll(options);
              if (options && options.type && options.type !== 'window' && options.type !== 'all') return real;
              const ours = await gather();
              return ours.concat([...real].filter((client) => !ours.some((page) => page.url === client.url)));
            } });
            if (get) {
              Object.defineProperty(workerClients, 'get', { configurable: true, writable: true, value: async (id) => {
                const page = [...pages.values()].find((client) => client.id === id);
                return page || get(id);
              } });
            }
          } catch (e) {}
        };
        add((port) => {
          if (!port || port.name !== WORKER_PORT) return;
          rely();
          const url = (port.sender && port.sender.url) || '';
          const client = {
            id: `zigzag-${Date.now()}-${Math.random().toString(36).slice(2)}`, type: 'window', frameType: 'top-level', url,
            // A port handed over with the message (a MessageChannel's) can't travel this way: refused, as postMessage
            // refuses what it can't carry, so the caller takes its other way. Tampermonkey hands its offscreen page
            // one and waits on it for the answer, so it waited for good and .user.js links no longer opened its
            // install page.
            postMessage: (message, transfer) => {
              const handed = Array.isArray(transfer) ? transfer : transfer && transfer.transfer;
              if (handed && handed.length) throw new DOMException('A port or buffer handed over cannot reach this page.', 'DataCloneError');
              try { port.postMessage({ kind: 'message', data: carried(message) }); } catch (e) {}
            },
          };
          pages.set(port, client);
          if (keepOpen) keepOpen(port);
          // The worker's ends of the ports the page handed over (above), by the page's numbers.
          const ends = new Map();
          port.onMessage.addListener((message) => {
            if (!message) return;
            if (message.kind === 'port') {
              const end = ends.get(message.id);
              if (end) end.postMessage(restored(message.data));
              return;
            }
            if (message.kind !== 'message') return;
            const handed = (Array.isArray(message.ports) ? message.ports : []).map((id) => {
              const channel = new MessageChannel();
              ends.set(id, channel.port2);
              channel.port2.onmessage = (event) => { try { port.postMessage({ kind: 'port', id, data: carried(event.data) }); } catch (e) {} };
              return channel.port1;
            });
            const event = new MessageEvent('message', { data: restored(message.data), ports: handed });
            Object.defineProperty(event, 'source', { value: client });
            Object.defineProperty(event, 'waitUntil', { value: (promise) => { Promise.resolve(promise).catch(() => {}); } });
            globalThis.dispatchEvent(event);
          });
          port.onDisconnect.addListener(() => {
            pages.delete(port);
            for (const end of ends.values()) { try { end.close(); } catch (e) {} }
            ends.clear();
          });
        });
        // Violentmonkey makes its offscreen page and looks for it among its clients straight away, before the page
        // has posted anything; it may be an offscreen page left from the worker's last run.
        const offscreen = api.offscreen;
        if (offscreen && typeof offscreen.createDocument === 'function') {
          const create = offscreen.createDocument.bind(offscreen);
          setMember(['offscreen'], 'createDocument', (...args) => { rely(); return create(...args); });
        }
      }
      // The extension's pages inside tabs (above), at the background's end.
      if (background && api.tabs && typeof api.tabs.sendMessage === 'function') {
        const tabPages = new Map();
        let asked = 0;
        add((port) => {
          if (!port || port.name !== TAB_PORT) return;
          const sender = port.sender || {};
          if (!sender.tab || typeof sender.tab.id !== 'number') {
            try { port.postMessage({ kind: 'no-tab' }); port.disconnect(); } catch (e) {}
            return;
          }
          const page = { port, tabId: sender.tab.id, frameId: sender.frameId, documentId: sender.documentId, listening: false, waiting: new Map() };
          tabPages.set(port, page);
          if (keepOpen) keepOpen(port);
          port.onMessage.addListener((message) => {
            if (!message) return;
            if (message.kind === 'listening') page.listening = !!message.value;
            if (message.kind === 'tab-answer' && page.waiting.has(message.id)) {
              const resolve = page.waiting.get(message.id);
              page.waiting.delete(message.id);
              resolve(message.none ? { none: true } : { value: message.value });
            }
          });
          port.onDisconnect.addListener(() => {
            tabPages.delete(port);
            for (const resolve of page.waiting.values()) resolve({ none: true });
            page.waiting.clear();
          });
        });
        const from = { id: api.runtime.id, url: (() => { try { return location.href; } catch (e) { return undefined; } })() };
        const ask = (page, message) => new Promise((resolve) => {
          const id = ++asked;
          page.waiting.set(id, resolve);
          try { page.port.postMessage({ kind: 'tab-message', id, message: portable(message), sender: from }); } catch (e) { page.waiting.delete(id); resolve({ none: true }); }
        });
        const sendToTab = api.tabs.sendMessage.bind(api.tabs);
        setMember(['tabs'], 'sendMessage', (tabId, message, ...rest) => {
          const options = rest[0] && typeof rest[0] === 'object' ? rest[0] : null;
          const pages = [...tabPages.values()].filter((page) => page.listening && page.tabId === tabId
            && (!options || options.frameId == null || page.frameId === options.frameId)
            && (!options || options.documentId == null || page.documentId === options.documentId));
          // No page of its own there: exactly as WebKit sends it.
          if (!pages.length) return sendToTab(tabId, message, ...rest);
          const callback = typeof rest[rest.length - 1] === 'function' ? rest.pop() : null;
          // Aimed at one frame or document, and it's one of the pages: content scripts don't run there.
          const scripts = options && (options.frameId != null || options.documentId != null) ? null
            : Promise.resolve().then(() => sendToTab(tabId, message, ...rest));
          // As in Chrome, the first answer wins; with none, the message still arrived, so no error.
          const answer = new Promise((resolve) => {
            let left = pages.length + (scripts ? 1 : 0);
            let done = false;
            const settle = (answered, value) => {
              if (done) return;
              if (answered || --left === 0) { done = true; resolve(answered ? value : undefined); }
            };
            if (scripts) scripts.then((value) => settle(value !== undefined, value), () => settle(false));
            for (const page of pages) ask(page, message).then((reply) => settle(!reply.none, reply.value));
          });
          if (!callback) return answer;
          answer.then((value) => callback(value));
          return undefined;
        });
      }
      const shown = new WeakMap();
      setMember(['runtime', 'onConnect'], 'addListener', (listener) => {
        if (typeof listener !== 'function') return extensionAdd(listener);
        const wrapped = (port, ...rest) => { if (!port || (port.name !== WORKER_PORT && port.name !== TAB_PORT)) return listener(port, ...rest); };
        shown.set(listener, wrapped);
        return extensionAdd(wrapped);
      });
      if (remove) setMember(['runtime', 'onConnect'], 'removeListener', (listener) => remove(shown.get(listener) || listener));
      if (has) setMember(['runtime', 'onConnect'], 'hasListener', (listener) => has(shown.get(listener) || listener));
    }

    // webRequest.onAuthRequired: its listeners also answer sign-ins, a site's or the proxy the extension sets, as the
    // bridge asks them (bridge.js). WebKit's own still hears what it can.
    const signIn = globalThis.__zigzagSignIn;
    const authRequired = api.webRequest && api.webRequest.onAuthRequired;
    if (signIn && authRequired && typeof authRequired.addListener === 'function') {
      const add = authRequired.addListener.bind(authRequired);
      const remove = authRequired.removeListener && authRequired.removeListener.bind(authRequired);
      const has = authRequired.hasListener && authRequired.hasListener.bind(authRequired);
      try {
        setMember(['webRequest', 'onAuthRequired'], 'addListener', (listener, filter, extraInfoSpec, ...rest) => {
          signIn.add(listener, filter, extraInfoSpec);
          // WebKit refuses the blocking options it can't honor; it still watches without them.
          try { return add(listener, filter, extraInfoSpec, ...rest); } catch (e) {}
          try { return add(listener, filter); } catch (e) {}
        });
        setMember(['webRequest', 'onAuthRequired'], 'removeListener', (listener) => { signIn.remove(listener); if (remove) return remove(listener); });
        setMember(['webRequest', 'onAuthRequired'], 'hasListener', (listener) => signIn.has(listener) || (has ? has(listener) : false));
      } catch (e) {}
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
