// A site an installed extension lets message it (its manifest's externally_connectable.matches) may call
// chrome.runtime.sendMessage(id, …), as sites written for Chrome do (claude.ai, to finish Claude's sign-in). WebKit
// offers that as browser.runtime, so on those sites alone it's offered under Chrome's name too, with Chrome's
// callbacks. Every other page is left as it was: no `chrome` that would make it think it's in Chrome.
(() => {
  const patterns = __PATTERNS__;
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
  if (!patterns.some(matches)) return;
  const runtime = window.browser && window.browser.runtime;
  if (window.chrome || !runtime || typeof runtime.sendMessage !== 'function') return;
  const withCallback = (fn) => (...args) => {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const result = fn.apply(runtime, args);
    if (!callback) return result;
    Promise.resolve(result).then((value) => callback(value), () => callback(undefined));
  };
  const chromeRuntime = { sendMessage: withCallback(runtime.sendMessage) };
  if (typeof runtime.connect === 'function') chromeRuntime.connect = (...args) => runtime.connect(...args);
  Object.defineProperty(window, 'chrome', { value: Object.freeze({ runtime: Object.freeze(chromeRuntime) }), configurable: true });
})();
