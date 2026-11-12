// Full screen in the page (#168): with Settings › Tabs › Full screen videos fill set to The Page, or a site's own
// choice in its controls, a page asking for full screen (a player's button, Element.requestFullscreen and its webkit
// names, video.webkitEnterFullscreen) gets its element filling the page's own area instead of the whole screen. The
// page is told it's in full screen as it would be (fullscreenElement, fullscreenchange), its own :fullscreen styles
// are matched through a mark, and Esc leaves. A frame asks the page around it to fill the page with the frame, all
// the way up. Otherwise everything is WebKit's own.
(() => {
  const KEY = Symbol.for('zigzag.fullscreen');
  if (window[KEY]) return;
  let config = __CONFIG__;
  const MARK = 'data-zigzag-fullscreen';
  const ANCESTOR = 'data-zigzag-fullscreen-ancestor';
  const PAGE = 'data-zigzag-fullscreen-page';
  const MESSAGE = '__zigzagFullScreen';
  const isTop = window === window.top;

  // Whose choice it is: the site of the tab's page, for a frame as for the page.
  const siteOf = (host) => (host || '').toLowerCase().replace(/^www\./, '');
  const topHost = () => {
    if (isTop) return location.hostname;
    try { const a = location.ancestorOrigins; if (a && a.length) return new URL(a[a.length - 1]).hostname; } catch (e) {}
    try { return window.top.location.hostname; } catch (e) { return location.hostname; }
  };
  const covers = (list, site) => (list || []).some((s) => site === s || site.endsWith('.' + s));
  const fillsPage = () => {
    const site = siteOf(topHost());
    if (covers(config.page, site)) return true;
    if (covers(config.screen, site)) return false;
    return config.fill === 'page';
  };

  const E = Element.prototype, D = Document.prototype, V = window.HTMLVideoElement && HTMLVideoElement.prototype;
  const own = (o, n) => (o ? Object.getOwnPropertyDescriptor(o, n) : undefined);
  const native = {
    request: E.requestFullscreen, webkitRequest: E.webkitRequestFullscreen, webkitRequestS: E.webkitRequestFullScreen,
    exit: D.exitFullscreen, webkitExit: D.webkitExitFullscreen, webkitCancel: D.webkitCancelFullScreen,
    element: own(D, 'fullscreenElement'), webkitElement: own(D, 'webkitFullscreenElement'),
    webkitCurrent: own(D, 'webkitCurrentFullScreenElement'), webkitIs: own(D, 'webkitIsFullScreen'), fullscreen: own(D, 'fullscreen'),
    videoEnter: V && V.webkitEnterFullscreen, videoEnterS: V && V.webkitEnterFullScreen,
    videoExit: V && V.webkitExitFullscreen, videoExitS: V && V.webkitExitFullScreen,
    videoDisplaying: own(V, 'webkitDisplayingFullscreen'), videoMode: own(V, 'webkitPresentationMode'),
  };
  const nativeElement = () => {
    try { return (native.element ? native.element.get.call(document) : native.webkitElement && native.webkitElement.get.call(document)) || null; } catch (e) { return null; }
  };

  // The element filling the page (in the page around a frame, the frame), whether it came from a video's own
  // full screen, and what was in its style and its ancestors' before.
  let current = null, viaVideo = false, saved = [], sheet = null;

  const fill = {
    position: 'fixed', top: '0', right: '0', bottom: '0', left: '0', width: '100vw', height: '100vh',
    'min-width': '0', 'min-height': '0', 'max-width': 'none', 'max-height': 'none', margin: '0', 'box-sizing': 'border-box',
    'z-index': '2147483647', transform: 'none', translate: 'none', scale: 'none', rotate: 'none',
  };
  // What WebKit puts on a full screen element's ancestors, so nothing they make (a stacking order, a transform that
  // holds fixed children, a filter) keeps it inside them.
  const freed = {
    'z-index': 'auto', isolation: 'auto', opacity: '1', filter: 'none', 'backdrop-filter': 'none', transform: 'none',
    translate: 'none', scale: 'none', rotate: 'none', perspective: 'none', 'clip-path': 'none', mask: 'none',
    contain: 'none', 'will-change': 'auto', transition: 'none', 'content-visibility': 'visible',
  };
  const setStyle = (el, props) => {
    const before = {};
    for (const p of Object.keys(props)) {
      before[p] = [el.style.getPropertyValue(p), el.style.getPropertyPriority(p)];
      el.style.setProperty(p, props[p], 'important');
    }
    saved.push([el, before]);
  };
  const restoreStyles = () => {
    for (const [el, before] of saved.reverse()) {
      for (const p of Object.keys(before)) {
        const [value, priority] = before[p];
        if (value) el.style.setProperty(p, value, priority); else el.style.removeProperty(p);
      }
      if (el.getAttribute('style') === '') el.removeAttribute('style');
    }
    saved = [];
  };
  const parentOf = (el) => el.parentElement || (el.getRootNode && el.getRootNode() instanceof ShadowRoot ? el.getRootNode().host : null);

  // The page's own :fullscreen rules, matched through the mark: each same-origin sheet's rules that name it,
  // copied with the mark in its place (in @media and @supports as they were).
  const pseudo = /:(?:-webkit-)?full-?screen-ancestor\b|:-webkit-full-screen-document\b|:(?:-webkit-)?full-?screen\b/gi;
  const rewrite = (selector) => selector.replace(pseudo, (m) => {
    const name = m.toLowerCase();
    if (name.endsWith('ancestor')) return `[${ANCESTOR}]`;
    if (name.endsWith('document')) return `[${PAGE}]`;
    return `[${MARK}]`;
  });
  const copyRules = (rules, out) => {
    for (const rule of rules) {
      if (rule instanceof CSSStyleRule) {
        pseudo.lastIndex = 0;
        if (pseudo.test(rule.selectorText)) out.push(`${rewrite(rule.selectorText)} { ${rule.style.cssText} }`);
      } else if ((window.CSSMediaRule && rule instanceof CSSMediaRule) || (window.CSSSupportsRule && rule instanceof CSSSupportsRule)) {
        const inner = [];
        try { copyRules(rule.cssRules, inner); } catch (e) {}
        if (inner.length) out.push(`${rule instanceof CSSMediaRule ? '@media ' + rule.media.mediaText : '@supports ' + rule.conditionText} { ${inner.join('\n')} }`);
      }
    }
  };
  const base = [
    `html[${PAGE}], html[${PAGE}] body { overflow: hidden !important; }`,
    `video[${MARK}] { object-fit: contain !important; }`,
    `iframe[${MARK}] { border: 0 !important; }`,
  ];
  const addSheet = () => {
    const rules = base.slice();
    for (const s of document.styleSheets) {
      try { copyRules(s.cssRules, rules); } catch (e) {}
    }
    const style = document.createElement('style');
    style.setAttribute(MARK + '-style', '');
    (document.head || document.documentElement).appendChild(style);
    for (const rule of rules) { try { style.sheet.insertRule(rule, style.sheet.cssRules.length); } catch (e) {} }
    sheet = style;
  };

  const tell = (target, type) => {
    try { target.dispatchEvent(new Event(type, { bubbles: true, composed: true })); } catch (e) {}
  };
  const changed = (el, video, entering) => {
    const target = el && el.isConnected ? el : document;
    tell(target, 'fullscreenchange');
    tell(target, 'webkitfullscreenchange');
    if (video && el) tell(el, entering ? 'webkitbeginfullscreen' : 'webkitendfullscreen');
    if (video && el) tell(el, 'webkitpresentationmodechanged');
    try { window.dispatchEvent(new Event('resize')); } catch (e) {}
  };
  const report = () => {
    if (!isTop) return;
    try { window.webkit.messageHandlers.zigzagFullScreen.postMessage(!!current); } catch (e) {}
  };
  const frameFor = (source) => {
    for (const f of document.querySelectorAll('iframe, frame')) { if (f.contentWindow === source) return f; }
    return null;
  };
  const post = (target, type, extra) => { try { target.postMessage(Object.assign({ [MESSAGE]: type }, extra || {}), '*'); } catch (e) {} };

  function enter(el, video) {
    if (current === el) return;
    if (current) leave({ quiet: true });
    current = el;
    viaVideo = !!video;
    el.setAttribute(MARK, '');
    document.documentElement.setAttribute(PAGE, '');
    const look = getComputedStyle(el);
    const ground = look.backgroundColor;
    setStyle(el, ground === 'rgba(0, 0, 0, 0)' || ground === 'transparent' ? Object.assign({ 'background-color': 'black' }, fill) : fill);
    for (let a = parentOf(el); a && a !== document.documentElement; a = parentOf(a)) {
      a.setAttribute(ANCESTOR, '');
      setStyle(a, freed);
    }
    addSheet();
    if (!isTop) post(window.parent, 'enter');
    changed(el, viaVideo, true);
    report();
  }

  function leave(options) {
    const el = current;
    if (!el) return;
    const video = viaVideo;
    current = null;
    viaVideo = false;
    restoreStyles();
    el.removeAttribute(MARK);
    for (const a of document.querySelectorAll(`[${ANCESTOR}]`)) a.removeAttribute(ANCESTOR);
    for (let a = parentOf(el); a; a = parentOf(a)) a.removeAttribute(ANCESTOR);
    document.documentElement.removeAttribute(PAGE);
    if (sheet) { sheet.remove(); sheet = null; }
    // A frame filling the page leaves with it; the page around a frame that left leaves too.
    if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') { if (!(options && options.fromChild)) post(el.contentWindow, 'exit'); }
    if (!isTop && !(options && options.fromParent)) post(window.parent, 'exit');
    if (!(options && options.quiet)) changed(el, video, false);
    report();
  }

  // As WebKit does: the change is told in a moment, then the promise settles.
  const later = (work) => new Promise((resolve) => setTimeout(() => { work(); resolve(); }, 0));
  const requested = function (fallback) {
    return function (...args) {
      if (!fillsPage()) return fallback ? fallback.apply(this, args) : Promise.reject(new TypeError('Not supported'));
      const el = this;
      return later(() => { if (el.isConnected) enter(el, false); });
    };
  };
  const exited = function (fallback) {
    return function (...args) {
      if (!current) return fallback ? fallback.apply(this, args) : Promise.reject(new TypeError('Not in full screen'));
      return later(() => leave());
    };
  };
  // The standard names always; WebKit's own only where this WebKit still has them.
  const standard = new Set(['requestFullscreen', 'exitFullscreen', 'fullscreenElement', 'fullscreen']);
  const define = (o, n, value) => {
    if (!o || !(n in o) && !standard.has(n)) return;
    try { Object.defineProperty(o, n, Object.assign({ configurable: true }, value.descriptor)); } catch (e) {}
  };
  const method = (fn) => ({ descriptor: { value: fn, writable: true, enumerable: false } });
  const getter = (fn) => ({ descriptor: { get: fn, enumerable: true } });

  // What the page is told: its element, retargeted out of a shadow tree as WebKit's is.
  const seen = (doc) => {
    if (!current) return null;
    if (!current.isConnected) { leave(); return null; }
    let el = current;
    while (el && el.getRootNode() !== doc) el = el.getRootNode().host;
    return el || null;
  };
  const read = (descriptor) => function () { return seen(this) || (descriptor ? descriptor.get.call(this) : null); };

  define(E, 'requestFullscreen', method(requested(native.request)));
  define(E, 'webkitRequestFullscreen', method(requested(native.webkitRequest)));
  define(E, 'webkitRequestFullScreen', method(requested(native.webkitRequestS)));
  define(D, 'exitFullscreen', method(exited(native.exit)));
  define(D, 'webkitExitFullscreen', method(exited(native.webkitExit)));
  define(D, 'webkitCancelFullScreen', method(exited(native.webkitCancel)));
  define(D, 'fullscreenElement', getter(read(native.element)));
  define(D, 'webkitFullscreenElement', getter(read(native.webkitElement)));
  define(D, 'webkitCurrentFullScreenElement', getter(read(native.webkitCurrent)));
  define(D, 'webkitIsFullScreen', getter(function () { return !!seen(this) || !!(native.webkitIs && native.webkitIs.get.call(this)); }));
  define(D, 'fullscreen', getter(function () { return !!seen(this) || !!(native.fullscreen && native.fullscreen.get.call(this)); }));
  if (V) {
    const videoEnter = (fallback) => function (...args) {
      if (!fillsPage()) return fallback ? fallback.apply(this, args) : undefined;
      if (this.isConnected) enter(this, true);
    };
    const videoExit = (fallback) => function (...args) {
      if (current !== this) return fallback ? fallback.apply(this, args) : undefined;
      leave();
    };
    define(V, 'webkitEnterFullscreen', method(videoEnter(native.videoEnter)));
    define(V, 'webkitEnterFullScreen', method(videoEnter(native.videoEnterS)));
    define(V, 'webkitExitFullscreen', method(videoExit(native.videoExit)));
    define(V, 'webkitExitFullScreen', method(videoExit(native.videoExitS)));
    define(V, 'webkitDisplayingFullscreen', getter(function () { return current === this || !!(native.videoDisplaying && native.videoDisplaying.get.call(this)); }));
    define(V, 'webkitPresentationMode', getter(function () { return current === this && viaVideo ? 'fullscreen' : native.videoMode ? native.videoMode.get.call(this) : 'inline'; }));
  }

  // Esc leaves, before the page hears it, as it does WebKit's full screen.
  window.addEventListener('keydown', (event) => {
    if (!current || event.key !== 'Escape' || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
    event.stopImmediatePropagation();
    event.preventDefault();
    leave();
  }, true);

  // Full screen WebKit started itself (a video's own controls), while the page is to be filled: back out of it, and
  // fill the page with the same element.
  // Only WebKit's own events count: the ones told here are the page's to hear.
  let backingOut = false;
  const tookScreen = (event) => {
    if (!event.isTrusted || backingOut || !fillsPage()) return;
    const el = nativeElement();
    if (!el) return;
    backingOut = true;
    event.stopImmediatePropagation();
    const done = () => { backingOut = false; if (el.isConnected) enter(el, el instanceof HTMLVideoElement); };
    try { Promise.resolve(native.exit ? native.exit.call(document) : native.webkitExit.call(document)).then(done, done); } catch (e) { done(); }
  };
  document.addEventListener('fullscreenchange', tookScreen, true);
  document.addEventListener('webkitfullscreenchange', tookScreen, true);
  // A video's own full screen, apart from the page's.
  document.addEventListener('webkitbeginfullscreen', (event) => {
    const video = event.target;
    if (!event.isTrusted || !fillsPage() || !(video instanceof HTMLVideoElement) || !native.videoExit) return;
    event.stopImmediatePropagation();
    try { native.videoExit.call(video); } catch (e) {}
    setTimeout(() => { if (video.isConnected) enter(video, true); }, 0);
  }, true);

  window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || typeof data !== 'object' || !(MESSAGE in data)) return;
    const type = data[MESSAGE];
    if (event.source === window.parent && !isTop) {
      if (type === 'exit' && current) leave({ fromParent: true });
      if (type === 'config' && data.config) apply(data.config);
      return;
    }
    const frame = frameFor(event.source);
    if (!frame) return;
    if (type === 'enter' && fillsPage()) enter(frame, false);
    if (type === 'exit' && current === frame) leave({ fromChild: true });
  });

  // From Zigzag: the choices changed, passed down to every frame; or Esc pressed in its window.
  const apply = (next) => {
    config = next;
    for (const f of document.querySelectorAll('iframe, frame')) post(f.contentWindow, 'config', { config: next });
    if (current && !fillsPage()) leave();
  };
  // A page that starts is never in full screen, whatever the one before it was.
  report();
  Object.defineProperty(window, KEY, {
    value: Object.freeze({ apply, exit: () => { if (current) { leave(); return true; } return false; }, get active() { return !!current; } }),
    enumerable: false, configurable: false, writable: false,
  });
})();
