// The Chrome Web Store's own button, for Zigzag. The store enables "Add to Chrome" only where the page has
// chrome.webstorePrivate and chrome.management (the install API Chrome gives that one site), so on that site alone
// they're here: adding goes through Zigzag's own review sheet, removing through its own question, and the button reads
// Zigzag where it reads Chrome. The user agent stays Safari's. Every other page, and every frame, is left as it was.
(() => {
  if (location.protocol !== 'https:' || location.host !== 'chromewebstore.google.com' || window.top !== window) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.zigzagWebStore;
  if (!handler) return;
  const ask = (kind, id) => handler.postMessage(id ? { kind, id } : { kind });

  const chrome = window.chrome || (window.chrome = {});
  const runtime = chrome.runtime || (chrome.runtime = {});
  // Chrome's way of saying a call failed: set only while the callback runs.
  const answer = (callback, value, error) => {
    if (typeof callback !== 'function') return;
    if (error) runtime.lastError = { message: error };
    try { callback(value); } finally { if (error) delete runtime.lastError; }
  };
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (f) => { if (typeof f === 'function') listeners.add(f); },
      removeListener: (f) => listeners.delete(f),
      hasListener: (f) => listeners.has(f),
      fire: (...args) => listeners.forEach((f) => { try { f(...args); } catch (e) {} }),
    };
  };
  const onInstalled = event(), onUninstalled = event();
  // What was installed when the store last asked, so coming back to the tab after a change elsewhere (Settings)
  // tells the store to look again.
  let known = null;
  // Names of what's installed, so the store's "… has been removed from Chrome." can be told apart.
  const names = new Map();
  let removed = null;
  const list = () => ask('list').then((items) => {
    const all = Array.isArray(items) ? items : [];
    known = all.map((item) => item.id + ':' + item.enabled).sort().join(',');
    all.forEach((item) => { if (item.name) names.set(item.id, item.name); });
    return all;
  });
  // Chrome's ExtensionInfo, as much of it as the store reads.
  const info = (item) => ({ id: item.id, name: item.name, shortName: item.name, version: item.version, enabled: item.enabled,
    installType: 'normal', type: 'extension', mayDisable: true, isApp: false, offlineEnabled: false, description: '',
    permissions: [], hostPermissions: [], icons: [] });

  chrome.management = Object.assign(chrome.management || {}, {
    getAll(callback) {
      const done = list().then((items) => items.map(info), () => []);
      if (typeof callback !== 'function') return done;
      done.then((items) => answer(callback, items));
    },
    uninstall(id, options, callback) {
      const cb = typeof options === 'function' ? options : callback;
      ask('remove', String(id)).then((gone) => {
        if (gone) {
          known = null;
          removed = names.has(String(id)) ? { name: names.get(String(id)), until: Date.now() + 10000 } : null;
        }
        answer(cb, undefined, gone ? null : 'User cancelled uninstall');
        if (gone) onUninstalled.fire(String(id));
      }, () => answer(cb, undefined, 'User cancelled uninstall'));
    },
    onInstalled,
    onUninstalled,
  });

  chrome.webstorePrivate = Object.assign(chrome.webstorePrivate || {}, {
    // "installable", "enabled" or "disabled", as Chrome answers for an extension.
    getExtensionStatus(id, manifest, callback) {
      const cb = typeof manifest === 'function' ? manifest : callback;
      ask('status', String(id)).then((status) => answer(cb, status), () => answer(cb, 'installable'));
    },
    // Chrome asks here, in its own dialog; Zigzag downloads, shows its review sheet and adds it, then answers ""
    // once it's in. Anything else is "user_cancelled": Zigzag has already said what went wrong in its own words.
    beginInstallWithManifest3(details, callback) {
      const id = details && String(details.id);
      ask('install', id).then((added) => answer(callback, added ? '' : 'user_cancelled'), () => answer(callback, 'user_cancelled'));
    },
    // Already added by the time Chrome would get here: the store hears it's in, and looks again.
    completeInstall(id, callback) {
      known = null;
      answer(callback);
      list().then((items) => {
        const item = items.find((i) => i.id === String(id));
        if (item) onInstalled.fire(info(item));
      }, () => {});
    },
    isInIncognitoMode(callback) { answer(callback, false); },
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible' || known === null) return;
    const before = known;
    list().then((items) => { if (known !== before) onInstalled.fire(items[0] ? info(items[0]) : {}); }, () => {});
  });

  // The store writes its button as "Add to Chrome" / "Remove from Chrome" in the page's language, and writes it
  // again whenever it redraws: each time, Chrome becomes Zigzag in the button alone.
  // So is the message it shows once one is removed ("JSON Formatter has been removed from Chrome."): only the one
  // naming what was just removed, so nothing else the page says about Chrome changes.
  const rename = (root) => {
    for (const label of root.querySelectorAll('[jscontroller="ri2s0b"] button span')) {
      const text = label.firstChild;
      if (label.childNodes.length === 1 && text.nodeType === Node.TEXT_NODE && text.data.includes('Chrome')) {
        text.data = text.data.replace(/Chrome/g, 'Zigzag');
      }
    }
    if (removed && Date.now() < removed.until) {
      for (const region of root.querySelectorAll('[aria-live]')) {
        const walker = document.createTreeWalker(region, NodeFilter.SHOW_TEXT);
        for (let text = walker.nextNode(); text; text = walker.nextNode()) {
          if (text.data.includes(removed.name) && text.data.includes('Chrome')) text.data = text.data.replace(/Chrome/g, 'Zigzag');
        }
      }
    }
  };
  // The store's "Switch to Chrome to install extensions" banner and its "Switch to Chrome?" card: here the store's
  // own button works, so neither is true.
  const hide = () => {
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync('[jscontroller="o2G9me"]:has([jsname="oGfC5c"]), [role="dialog"][aria-labelledby="promo-header"] { display: none !important; }');
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    } catch (e) {}
  };
  const observer = new MutationObserver(() => rename(document));
  const start = () => {
    hide();
    rename(document);
    observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
  };
  if (document.documentElement) start(); else document.addEventListener('readystatechange', start, { once: true });
})();
