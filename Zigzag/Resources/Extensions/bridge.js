// Chrome extension APIs WebKit doesn't have, answered by Zigzag itself (ExtensionBridge.swift).
//
// Runs before an extension's own code, in its background and in its pages. Each namespace here is installed only
// when the extension asked for its permission in its manifest, and only when WebKit doesn't already provide it. Calls
// travel as native messages to "zigzag.bridge"; events come back over a port opened once something listens.
(() => {
  const api = globalThis.chrome || globalThis.browser;
  if (!api || !api.runtime || typeof api.runtime.sendNativeMessage !== 'function' || globalThis.__zigzagBridge) return;
  globalThis.__zigzagBridge = true;
  const HOST = 'zigzag.bridge';

  let manifest = {};
  try { manifest = api.runtime.getManifest() || {}; } catch (e) {}
  const asked = new Set([...(manifest.permissions || []), ...(manifest.optional_permissions || [])]);

  // Only what JSON carries crosses over: callbacks and undefined drop out.
  const clean = (value) => (value === undefined ? null : JSON.parse(JSON.stringify(value)));

  const send = (ns, fn, args) =>
    Promise.resolve(api.runtime.sendNativeMessage(HOST, { ns, fn, args: args.map(clean) })).then((reply) => {
      if (reply && typeof reply.error === 'string') throw new Error(reply.error);
      return reply ? reply.value : undefined;
    });

  // A Chrome-style method: a promise, or the trailing callback Chrome extensions often pass instead.
  const method = (ns, fn, { before, after } = {}) => (...args) => {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const result = send(ns, fn, before ? before(args) : args).then((value) => (after ? after(value, args) : value));
    if (!callback) return result;
    result.then((value) => callback(value), (error) => { console.warn(`chrome.${ns}.${fn}:`, error.message); callback(undefined); });
  };

  // Events: one port for all of them, opened the first time anything listens, reopened if it drops.
  const listeners = new Map();
  let port = null;
  const listen = (names) => { try { connect().postMessage({ listen: names }); } catch (e) {} };
  const connect = () => {
    if (port) return port;
    port = api.runtime.connectNative(HOST);
    port.onMessage.addListener((message) => {
      for (const listener of [...(listeners.get(message && message.event) || [])]) {
        try { listener(...(message.args || [])); } catch (e) { console.error(e); }
      }
    });
    port.onDisconnect.addListener(() => {
      port = null;
      if (listeners.size) setTimeout(() => listen([...listeners.keys()]), 1000);
    });
    return port;
  };
  const on = (name, listener) => {
    let set = listeners.get(name);
    if (!set) { set = new Set(); listeners.set(name, set); listen([name]); }
    set.add(listener);
  };
  const event = (name) => ({
    addListener(listener) { if (typeof listener === 'function') on(name, listener); },
    removeListener(listener) { const set = listeners.get(name); if (set) set.delete(listener); },
    hasListener(listener) { const set = listeners.get(name); return !!set && set.has(listener); },
    hasListeners() { const set = listeners.get(name); return !!set && set.size > 0; },
  });

  // Puts a namespace on chrome (and browser), unless WebKit has a working one of its own.
  const install = (name, value) => {
    if (!asked.has(name)) return;
    for (const target of new Set([globalThis.chrome, globalThis.browser])) {
      if (!target) continue;
      const existing = target[name];
      if (existing && typeof existing === 'object' && Object.keys(existing).length) continue;
      try { Object.defineProperty(target, name, { value, configurable: true, enumerable: true, writable: true }); } catch (e) {}
    }
  };

  install('history', {
    search: method('history', 'search'),
    getVisits: method('history', 'getVisits'),
    addUrl: method('history', 'addUrl'),
    deleteUrl: method('history', 'deleteUrl'),
    deleteRange: method('history', 'deleteRange'),
    deleteAll: method('history', 'deleteAll'),
    onVisited: event('history.onVisited'),
    onVisitRemoved: event('history.onVisitRemoved'),
  });

  install('topSites', { get: method('topSites', 'get') });

  install('bookmarks', {
    getTree: method('bookmarks', 'getTree'),
    getSubTree: method('bookmarks', 'getSubTree'),
    get: method('bookmarks', 'get'),
    getChildren: method('bookmarks', 'getChildren'),
    getRecent: method('bookmarks', 'getRecent'),
    search: method('bookmarks', 'search'),
    create: method('bookmarks', 'create'),
    update: method('bookmarks', 'update'),
    move: method('bookmarks', 'move'),
    remove: method('bookmarks', 'remove'),
    removeTree: method('bookmarks', 'removeTree'),
    onCreated: event('bookmarks.onCreated'),
    onRemoved: event('bookmarks.onRemoved'),
    onChanged: event('bookmarks.onChanged'),
    onMoved: event('bookmarks.onMoved'),
    onChildrenReordered: event('bookmarks.onChildrenReordered'),
    onImportBegan: event('bookmarks.onImportBegan'),
    onImportEnded: event('bookmarks.onImportEnded'),
    MAX_WRITE_OPERATIONS_PER_HOUR: 1000000,
    MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000,
  });

  install('downloads', {
    download: method('downloads', 'download'),
    search: method('downloads', 'search'),
    pause: method('downloads', 'pause'),
    resume: method('downloads', 'resume'),
    cancel: method('downloads', 'cancel'),
    erase: method('downloads', 'erase'),
    removeFile: method('downloads', 'removeFile'),
    open: (id) => { send('downloads', 'open', [id]).catch((e) => console.warn('chrome.downloads.open:', e.message)); },
    show: (id) => { send('downloads', 'show', [id]).catch(() => {}); },
    showDefaultFolder: () => { send('downloads', 'showDefaultFolder', []).catch(() => {}); },
    getFileIcon: method('downloads', 'getFileIcon'),
    setUiOptions: method('downloads', 'setUiOptions'),
    setShelfEnabled: () => {},
    acceptDanger: method('downloads', 'acceptDanger'),
    onCreated: event('downloads.onCreated'),
    onChanged: event('downloads.onChanged'),
    onErased: event('downloads.onErased'),
    // Zigzag names files itself; an extension can't step in before it does.
    onDeterminingFilename: event('downloads.onDeterminingFilename'),
    State: { IN_PROGRESS: 'in_progress', INTERRUPTED: 'interrupted', COMPLETE: 'complete' },
  });

  install('notifications', {
    // create(id?, options): the ID comes back, made up when none was given.
    create: method('notifications', 'create'),
    update: method('notifications', 'update'),
    clear: method('notifications', 'clear'),
    getAll: method('notifications', 'getAll'),
    getPermissionLevel: method('notifications', 'getPermissionLevel'),
    onClicked: event('notifications.onClicked'),
    onClosed: event('notifications.onClosed'),
    onButtonClicked: event('notifications.onButtonClicked'),
    onShowSettings: event('notifications.onShowSettings'),
    TemplateType: { BASIC: 'basic', IMAGE: 'image', LIST: 'list', PROGRESS: 'progress' },
    PermissionLevel: { GRANTED: 'granted', DENIED: 'denied' },
  });

  install('idle', {
    queryState: method('idle', 'queryState'),
    setDetectionInterval: (seconds) => { send('idle', 'setDetectionInterval', [seconds]).catch(() => {}); },
    getAutoLockDelay: method('idle', 'getAutoLockDelay'),
    onStateChanged: event('idle.onStateChanged'),
    IdleState: { ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked' },
  });

  // tts.speak's options carry an onEvent callback; it stays here, and Zigzag reports events by utterance.
  const utterances = new Map();
  let utteranceCount = 0;
  const utteranceEvents = (id, event) => {
    const callback = utterances.get(id);
    if (!callback) return;
    try { callback(event); } catch (e) { console.error(e); }
    if (['end', 'interrupted', 'cancelled', 'error'].includes(event.type)) utterances.delete(id);
  };
  install('tts', {
    speak: method('tts', 'speak', {
      before: ([text, options]) => {
        const rest = Object.assign({}, options);
        if (typeof rest.onEvent === 'function') {
          const id = `u${++utteranceCount}`;
          utterances.set(id, rest.onEvent);
          on('tts.utterance', utteranceEvents);
          rest.__utterance = id;
        }
        delete rest.onEvent;
        return [text, rest];
      },
    }),
    stop: () => { send('tts', 'stop', []).catch(() => {}); },
    pause: () => { send('tts', 'pause', []).catch(() => {}); },
    resume: () => { send('tts', 'resume', []).catch(() => {}); },
    isSpeaking: method('tts', 'isSpeaking'),
    getVoices: method('tts', 'getVoices'),
    onEvent: event('tts.onEvent'),
  });

  install('offscreen', {
    createDocument: method('offscreen', 'createDocument'),
    closeDocument: method('offscreen', 'closeDocument'),
    hasDocument: method('offscreen', 'hasDocument'),
    Reason: Object.fromEntries(['TESTING', 'AUDIO_PLAYBACK', 'IFRAME_SCRIPTING', 'DOM_SCRAPING', 'BLOBS', 'DOM_PARSER', 'USER_MEDIA',
      'DISPLAY_MEDIA', 'WEB_RTC', 'CLIPBOARD', 'LOCAL_STORAGE', 'WORKERS', 'BATTERY_STATUS', 'MATCH_MEDIA', 'GEOLOCATION'].map((r) => [r, r])),
  });

  install('identity', {
    launchWebAuthFlow: method('identity', 'launchWebAuthFlow'),
    getRedirectURL: (path) => `https://${api.runtime.id}.chromiumapp.org/${path || ''}`,
    getAuthToken: (...args) => {
      const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
      const error = new Error("Chrome's own account sign-in isn't available in Zigzag; use launchWebAuthFlow");
      if (callback) { setTimeout(() => callback(undefined), 0); return; }
      return Promise.reject(error);
    },
    removeCachedAuthToken: method('identity', 'getRedirectURL', { after: () => undefined }),
    clearAllCachedAuthTokens: () => Promise.resolve(),
    getProfileUserInfo: (...args) => {
      const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
      const info = { email: '', id: '' };
      if (callback) { setTimeout(() => callback(info), 0); return; }
      return Promise.resolve(info);
    },
    getAccounts: () => Promise.resolve([]),
    onSignInChanged: event('identity.onSignInChanged'),
  });

  install('power', {
    requestKeepAwake: (level) => { send('power', 'requestKeepAwake', [level]).catch(() => {}); },
    releaseKeepAwake: () => { send('power', 'releaseKeepAwake', []).catch(() => {}); },
    Level: { SYSTEM: 'system', DISPLAY: 'display' },
  });
})();
