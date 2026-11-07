// A site an installed extension lets message it (its manifest's externally_connectable.matches) may call
// chrome.runtime.sendMessage(id, …), as sites written for Chrome do (claude.ai, to finish Claude's sign-in). WebKit
// offers that as browser.runtime, so on those sites alone it's offered under Chrome's name too, with Chrome's
// callbacks. Every other page is left as it was: no `chrome` that would make it think it's in Chrome.
(() => {
  const patterns = __PATTERNS__;   // extension ID -> the sites it lets message it
  // Chrome's match patterns ("https://*.claude.ai/*"): scheme, host (a leading "*." for any subdomain), path.
  const matches = (pattern) => {
    const m = /^(\*|https?):\/\/(\*|(?:\*\.)?[^/*]+)(\/.*)$/.exec(pattern);
    if (!m) return false;
    const [, scheme, host, path] = m;
    if (scheme === '*' ? !/^https?:$/.test(location.protocol) : location.protocol !== scheme + ':') return false;
    if (host !== '*') {
      const bare = host.replace(/^\*\./, '');
      if (!(location.hostname === bare || (host.startsWith('*.') && location.hostname.endsWith('.' + bare)))) return false;
    }
    const glob = new RegExp('^' + path.split('*').map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$');
    return glob.test(location.pathname + location.search);
  };
  // The extensions that let this page message them: a message for any other gets Chrome's answer at once.
  const reachable = Object.keys(patterns).filter((id) => patterns[id].some(matches));
  if (!reachable.length) return;
  const runtime = window.browser && window.browser.runtime;
  if (!runtime || typeof runtime.sendMessage !== 'function') return;
  // These sites decide from the browser's name whether to hand things to the extension (claude.ai finishing Claude's
  // sign-in does): here, where an extension asked to be reached, the page reads Chrome, as the extension was built for.
  // What's sent to the server is unchanged.
  const asChrome = navigator.userAgent.replace(/Version\/[\d.]+ Safari\/[\d.]+/, 'Chrome/140.0.0.0 Safari/537.36');
  const proto = Object.getPrototypeOf(navigator);
  const brands = Object.freeze([{ brand: 'Chromium', version: '140' }, { brand: 'Google Chrome', version: '140' }, { brand: 'Not=A?Brand', version: '24' }]);
  const userAgentData = { brands, mobile: false, platform: 'macOS', getHighEntropyValues: async () => ({ brands, mobile: false, platform: 'macOS', fullVersionList: brands }), toJSON: () => ({ brands, mobile: false, platform: 'macOS' }) };
  for (const [key, value] of [['userAgent', asChrome], ['appVersion', asChrome.replace(/^Mozilla\//, '')], ['vendor', 'Google Inc.'], ['userAgentData', userAgentData]]) {
    try { Object.defineProperty(proto, key, { get: () => value, configurable: true, enumerable: true }); } catch (e) {}
  }
  if (window.chrome) return;
  // Chrome's sendMessage(extensionId?, message, options?, callback?): WebKit's takes no options, and refuses the call
  // outright when given some, so they're left out (they only say whether to include a TLS channel ID).
  const sendMessage = (...args) => {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const [first, second] = args;
    const toExtension = typeof first === 'string' && args.length >= 2;
    const call = toExtension ? [first, second] : [first];
    let result;
    // Sites try a list of extension IDs and take the one that answers (claude.ai, for Claude's builds). Chrome refuses
    // one that isn't installed at once; WebKit never answers, and the site would wait forever on the first.
    if (toExtension && !reachable.includes(first)) {
      result = Promise.reject(new Error('Could not establish connection. Receiving end does not exist.'));
    } else {
      try { result = runtime.sendMessage(...call); } catch (error) { result = Promise.reject(error); }
    }
    result = Promise.resolve(result);
    if (!callback) return result;
    // As Chrome does: a failure reaches the callback with nothing, and chrome.runtime.lastError says why, only
    // while the callback runs (sites check it to try the next extension).
    result.then((value) => callback(value), (error) => {
      lastError = { message: (error && error.message) || 'Could not establish connection. Receiving end does not exist.' };
      try { callback(undefined); } finally { lastError = undefined; }
    });
    return undefined;
  };
  let lastError;
  const chromeRuntime = { sendMessage };
  Object.defineProperty(chromeRuntime, 'lastError', { get: () => lastError, enumerable: true });
  if (typeof runtime.connect === 'function') chromeRuntime.connect = (...args) => runtime.connect(...args);
  Object.defineProperty(window, 'chrome', { value: Object.freeze({ runtime: Object.freeze(chromeRuntime) }), configurable: true });
})();
