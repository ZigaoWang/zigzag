// Dark pages (Settings › Appearance): a page that's dark on its own is left alone, any other is drawn dark by Dark
// Reader's dynamic theme (darkreader.js, MIT, in Zigzag/Resources/DarkReader; see THIRD_PARTY_NOTICES.md), which
// rewrites the site's own style (its sheets, custom properties, inline styles, shadow roots) rather than filtering it.
// Runs in Zigzag's own script world, in every frame, from the start of the document. DarkPages.swift puts the
// choices in `config` below: { on: default for sites without a choice, sitesOn, sitesOff, sitesForced, native: sites
// last seen dark on their own, marker: the mark this site's own dark look sets on the root, prepaint: the ground a
// page starts on, topWanted and topForced: the top page's choice, for frames, theme: Dark Reader's theme, fix and
// frameFix: Dark Reader's fixes for the page and for its frames }, and Dark Reader itself where it's marked below.
//
// First the site gets to do it: the web view is dark wherever dark pages are on, so `prefers-color-scheme: dark`
// matches and a site with a dark theme of its own uses it. A page starts on a plain dark ground (`prepaint`), so no
// white shows first: its site's own dark if it was last seen dark (with the mark its dark look sets, `marker`), else
// the dark Dark Reader draws white as. Just before the first frame the page has its style in, it's looked at: one
// dark on its own keeps its own colors, any other is drawn by Dark Reader from that frame on. A page that switches its
// theme later is looked at again, with Dark Reader's style switched off.
(() => {
  if (window.__zigzagDark) return;
  const config = __CONFIG__;
  const isTop = window === window.top;
  const type = document.contentType || '';
  // A page left alone still says so: what Zigzag heard about the page before this one doesn't hold here.
  const leftAlone = () => {
    if (!isTop) return;
    try { window.webkit.messageHandlers.zigzagDark.postMessage({ darkened: false, native: false, site: '' }); } catch (e) {}
  };
  // A picture, video or PDF opened on its own has nothing to darken.
  if (!/html|xml|text\/plain/.test(type)) { leftAlone(); return; }
  // Web pages, files and Zigzag's own pages; an extension's own page is its own business. A frame with no address of
  // its own (about:blank, srcdoc) is part of the page around it.
  if (!(isTop ? /^(https?|file|about|zigzag):$/ : /^(https?|file|about):$/).test(location.protocol)) { leftAlone(); return; }

  const siteOf = (host) => host.toLowerCase().replace(/^www\./, '');
  const matches = (site, list) => list.some((s) => site === s || site.endsWith('.' + s));
  const site = siteOf(location.hostname || '');
  // A frame follows the top page's choice.
  const choice = () => (!isTop ? config.topWanted === true
    : matches(site, config.sitesOn) ? true : matches(site, config.sitesOff) ? false : config.on);
  // Force dark (the site panel, #134): darkened even when it looks dark on its own.
  const forced = () => (isTop ? matches(site, config.sitesForced || []) : config.topForced === true);
  let wanted = choice();
  // null until the page has been looked at; a site last seen dark starts as dark.
  let native = isTop && matches(site, config.native) ? true : null;
  let darkened = false;
  let lastSent = '';

  // MARK: Dark Reader

  // Dark Reader in this world alone: the page never sees it, and its `window.chrome` stand-in stays here.
  const DarkReader = (() => {
    const module = { exports: {} };
    const exports = module.exports;
    // The pictures it looks at (a background icon, to tell whether it needs turning light) it loads as data: URLs,
    // which a page's Content-Security-Policy can refuse even here, where an extension's own world wouldn't (Hacker
    // News allows its own images only): the picture then counted as missing and the page's icons went with it. So
    // its `Image` is this: a canvas, drawn with the picture as an image loads it where the page allows that, else
    // decoded without loading anything, by the page's own decoder for a bitmap or by Zigzag for an SVG.
    const Image = function () {
      const canvas = document.createElement('canvas');
      canvas.width = 0;
      canvas.height = 0;
      let done = false;
      const fail = () => { if (!done) { done = true; if (canvas.onerror) canvas.onerror(); } };
      const draw = (source, width, height) => {
        if (done) return;
        canvas.width = Math.max(1, Math.round(width));
        canvas.height = Math.max(1, Math.round(height));
        try { canvas.getContext('2d').drawImage(source, 0, 0, canvas.width, canvas.height); } catch (e) { fail(); return; }
        done = true;
        if (canvas.onload) canvas.onload();
      };
      // A data: URL's bytes, read here: fetching it is a request the page's policy could refuse too.
      const blobOf = (url) => {
        const comma = url.indexOf(',');
        const head = url.slice(5, comma);
        const body = url.slice(comma + 1);
        const text = /;base64$/i.test(head) ? atob(body) : decodeURIComponent(body);
        return new Blob([Uint8Array.from(text, (c) => c.charCodeAt(0))], { type: head.split(';')[0] });
      };
      const decode = async (url) => {
        if (!url.startsWith('data:')) { fail(); return; }
        try {
          if (/^data:image\/svg\+xml/i.test(url)) {
            const got = await window.webkit.messageHandlers.zigzagDarkImage.postMessage(url);
            if (!got || !got.png) { fail(); return; }
            const bytes = Uint8Array.from(atob(got.png), (c) => c.charCodeAt(0));
            const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
            draw(bitmap, got.width, got.height);
          } else {
            const bitmap = await createImageBitmap(blobOf(url));
            draw(bitmap, bitmap.width, bitmap.height);
          }
        } catch (e) { fail(); }
      };
      Object.defineProperty(canvas, 'src', {
        set(url) {
          const real = new window.Image();
          real.onload = () => draw(real, real.naturalWidth, real.naturalHeight);
          real.onerror = () => { decode(String(url)); };
          real.src = url;
        },
      });
      return canvas;
    };
    __DARKREADER__
    return module.exports;
  })();
  // What it can't fetch itself (a style sheet or picture from another site, without CORS) Zigzag fetches for it,
  // without cookies.
  DarkReader.setFetchMethod(async (address) => {
    const url = new URL(address, location.href);
    if (url.origin === location.origin || url.protocol === 'data:' || url.protocol === 'blob:') return fetch(url.href);
    const got = await window.webkit.messageHandlers.zigzagDarkFetch.postMessage(url.href);
    if (!got || typeof got.body !== 'string') throw new Error('Not fetched: ' + url.href);
    const bytes = Uint8Array.from(atob(got.body), (c) => c.charCodeAt(0));
    return new Response(bytes, { status: 200, headers: { 'Content-Type': got.type || '' } });
  });
  const theme = () => config.theme;
  // A frame's address isn't the page's: the fix for every address alone.
  const fix = () => (isTop ? config.fix : config.frameFix) || null;
  // Dark Reader's first pass over a big page's style takes a while, all in one go. Its own rough dark (its
  // "fallback": every surface on its dark, every text in its light) goes on first, so the page is drawn at once and
  // readable, and the pass runs just after that first paint. It comes off in the frame after the pass: style still
  // loading then has Dark Reader's own fallback (Zigzag's is apart from it, so Dark Reader never empties it early).
  const fallback = document.createElement('style');
  fallback.className = 'darkreader zigzag-dark-fallback';
  fallback.media = 'screen';
  const fallbackCSS = () => {
    const t = theme();
    return `html, body, body :not(iframe) { background-color: ${t.darkSchemeBackgroundColor} !important; `
      + `border-color: #776e62 !important; color: ${t.darkSchemeTextColor} !important; }`;
  };
  let started = 0;
  // The page's first paint with something in it, which WebKit holds back until there's enough to show: the pass
  // waits for it, so it doesn't hold the paint back too.
  let painted = isTop ? performance.getEntriesByName('first-contentful-paint').length > 0 : true;
  const paintWaiters = [];
  if (!painted) {
    try {
      new PerformanceObserver((list, observer) => {
        if (!list.getEntriesByName('first-contentful-paint').length) return;
        observer.disconnect();
        painted = true;
        paintWaiters.splice(0).forEach((f) => f());
      }).observe({ type: 'paint', buffered: true });
    } catch (e) { painted = true; }
  }
  // Just after the page's first paint, else the next frame; a page that isn't being drawn (a tab behind others) gets
  // neither, so a little later regardless.
  const startSoon = () => {
    const run = ++started;
    const go = () => {
      if (run !== started || !darkened) return;
      started++;
      DarkReader.enable(theme(), fix());
      requestAnimationFrame(() => { if (darkened) fallback.remove(); });
      setTimeout(() => { if (darkened) fallback.remove(); }, 1000);
    };
    if (painted) requestAnimationFrame(() => setTimeout(go, 0));
    else paintWaiters.push(() => setTimeout(go, 0));
    setTimeout(go, painted ? 150 : 1500);
  };
  const apply = (on) => {
    if (on === darkened) return;
    darkened = on;
    started++;
    if (on) {
      dropPrepaint();
      fallback.textContent = fallbackCSS();
      const root = document.head || document.documentElement;
      if (root && fallback.parentNode !== root) root.appendChild(fallback);
      startSoon();
    } else {
      fallback.remove();
      DarkReader.disable();
    }
    send();
  };

  // MARK: The site's own dark ground and mark

  // The plain dark ground a page starts on while it's not known whether it's dark on its own (`prepaint`).
  const prepaint = document.createElement('style');
  prepaint.setAttribute('data-zigzag-dark', 'prepaint');
  prepaint.textContent = config.prepaint || '';
  const putPrepaint = () => {
    const root = document.documentElement;
    if (isTop && config.prepaint && root && prepaint.parentNode !== root) root.appendChild(prepaint);
  };
  const dropPrepaint = () => { if (prepaint.parentNode) prepaint.remove(); };

  // A site that marks its dark look on the root by script (a class of "dark", data-theme="dark") draws light until that
  // script has run. Seen setting one, the site's pages start with it (`config.marker`), so its dark style applies from
  // the first sheet. Only a mark the site was seen setting itself, and only where the root has none of its own yet; the
  // site touching it makes it the site's, and one the site never touches by a moment after the page has loaded is
  // taken off again and forgotten (the site's look doesn't use it any more).
  const markAttributes = ['data-color-mode', 'data-theme', 'data-bs-theme', 'data-mode', 'data-color-scheme', 'data-mantine-color-scheme'];
  const markClasses = ['dark', 'dark-mode', 'theme-dark', 'dark-theme'];
  const lightClasses = ['light', 'light-mode', 'theme-light', 'light-theme'];
  const marksOn = (root) => {
    const out = [];
    if (!root || !root.getAttribute) return out;
    for (const a of markAttributes) if ((root.getAttribute(a) || '').toLowerCase() === 'dark') out.push('attr:' + a + '=dark');
    for (const c of markClasses) if (root.classList.contains(c)) out.push('class:' + c);
    return out;
  };
  // What the page came with, before any script of its own ran.
  const servedMarks = isTop ? marksOn(document.documentElement) : [];
  // The mark Zigzag put on the root, while the site hasn't touched it.
  let markPut = null;
  // The site took it off without using it: said once, so it's forgotten.
  let markDropped = false;
  const markWatch = new MutationObserver(() => {
    const root = document.documentElement;
    markWatch.disconnect();
    // The site's now; but a light look it asks for isn't held dark by the class left beside it.
    if (markPut && markPut.cls && root && lightClasses.some((c) => root.classList.contains(c))) root.classList.remove(markPut.cls);
    markPut = null;
  });
  const putMark = () => {
    const root = document.documentElement;
    const m = /^attr:([\w-]+)=dark$|^class:([\w-]+)$/.exec(config.marker || '');
    if (!root || !m) return;
    if (m[1]) {
      if (!markAttributes.includes(m[1]) || root.hasAttribute(m[1])) return;
      root.setAttribute(m[1], 'dark');
      markPut = { attr: m[1] };
    } else {
      if (!markClasses.includes(m[2]) || [...markClasses, ...lightClasses].some((c) => root.classList.contains(c))) return;
      root.classList.add(m[2]);
      markPut = { cls: m[2] };
    }
    markWatch.observe(root, { attributes: true, attributeFilter: [markPut.attr || 'class'] });
  };
  const releaseMark = () => {
    if (!markPut) return;
    markWatch.disconnect();
    const root = document.documentElement;
    if (root) { if (markPut.attr) root.removeAttribute(markPut.attr); else root.classList.remove(markPut.cls); }
    markPut = null;
    markDropped = true;
  };
  // The mark the site's dark look set by script, for Zigzag to keep: "" for none, undefined until the page has loaded
  // (a script setting it may not have run) or while it's the one Zigzag put.
  const markNow = () => {
    if (markDropped) return '';
    if (markPut || document.readyState !== 'complete') return undefined;
    const set = marksOn(document.documentElement).filter((m) => !servedMarks.includes(m));
    return set.length ? set[0] : '';
  };

  // MARK: Is the page dark on its own?

  // Any color the page's computed style gives (rgb(), oklch(), lab(), color()...) as sRGB, by drawing it: a page's own
  // design system may be written in any of them.
  let ink = null;
  const known = new Map();
  const rgba = (text) => {
    if (!text) return null;
    if (known.has(text)) return known.get(text);
    try {
      if (!ink) ink = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
      ink.clearRect(0, 0, 1, 1);
      ink.fillStyle = '#000';
      ink.fillStyle = text;
      ink.fillRect(0, 0, 1, 1);
      const d = ink.getImageData(0, 0, 1, 1).data;
      const c = { r: d[0], g: d[1], b: d[2], a: d[3] / 255 };
      if (known.size > 256) known.clear();
      known.set(text, c);
      return c;
    } catch (e) { return null; }
  };
  const lightness = (c) => (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255;

  // Dark Reader's own test for a site with a dark theme of its own (its detector.ts, MIT): points across the window,
  // each one's background light or not (its text, where the background is see-through), then the root and body.
  const drawsDark = () => {
    const rootStyle = getComputedStyle(document.documentElement);
    if (rootStyle.filter.includes('invert(1)') || rootStyle.colorScheme === 'dark') return true;
    const w = innerWidth, h = innerHeight;
    const stepX = Math.floor(w / Math.min(4, Math.ceil(w / 256))), stepY = Math.floor(h / Math.min(4, Math.ceil(h / 256)));
    const done = new Set();
    for (let y = Math.floor(stepY / 2); y < h; y += stepY) {
      for (let x = Math.floor(stepX / 2); x < w; x += stepX) {
        const el = document.elementFromPoint(x, y);
        if (!el || done.has(el) || el.tagName.toLowerCase() === 'img') continue;
        done.add(el);
        const style = el === document.documentElement ? rootStyle : getComputedStyle(el);
        const bg = rgba(style.backgroundColor);
        if (!bg) return false;
        if (bg.a === 1) {
          if (lightness(bg) > 0.6) return false;
        } else {
          const text = rgba(style.color);
          if (!text || lightness(text) < 0.4) return false;
        }
      }
    }
    const root = rgba(rootStyle.backgroundColor);
    const body = document.body ? rgba(getComputedStyle(document.body).backgroundColor) : { r: 0, g: 0, b: 0, a: 0 };
    if (!root || !body) return false;
    if (root.a === 0 && body.a === 0) {
      const text = rgba(rootStyle.color);
      if (text) return lightness(text) > 0.5;
    }
    const rootL = (1 - root.a) + root.a * lightness(root);
    return (1 - body.a) * rootL + body.a * lightness(body) < 0.5;
  };
  // Dark Reader's style, and Zigzag's ground: switched off to look at the page as it draws itself, and on again in
  // the same go, so nothing is drawn in between.
  const ownSheets = () => {
    const out = [];
    for (const s of document.styleSheets) {
      const node = s.ownerNode;
      if (node && node.classList && (node.classList.contains('darkreader') || node === prepaint)) out.push(s);
    }
    for (const s of document.adoptedStyleSheets || []) {
      try { if (s.cssRules[0] && s.cssRules[0].selectorText && s.cssRules[0].selectorText.startsWith('#__darkreader')) out.push(s); } catch (e) {}
    }
    return out.filter((s) => !s.disabled);
  };
  // True when the page draws itself dark, false when light.
  const isDarkOnItsOwn = () => {
    const meta = document.querySelector('meta[name="color-scheme"]');
    if (meta) {
      const content = (meta.content || '').toLowerCase().trim();
      if (content === 'dark' || content === 'only dark') return true;
      if (content === 'light' || content === 'only light') return false;
    }
    // A dark mark the site set itself (not one Zigzag put there to start it on its own dark).
    const root = document.documentElement;
    if (!markPut && (root.classList.contains('dark') || (document.body && document.body.classList.contains('dark'))
      || (root.dataset.theme || '').toLowerCase() === 'dark')) return true;
    const sheets = ownSheets();
    sheets.forEach((s) => { s.disabled = true; });
    try { return drawsDark(); } finally { sheets.forEach((s) => { s.disabled = false; }); }
  };
  // Whether there's a page to look at: a body with something drawn in it, and some style of its own.
  const hasStyle = () => {
    if (document.querySelector('meta[name="color-scheme"]')) return true;
    if (document.documentElement.style.backgroundColor || (document.body && document.body.style.backgroundColor)) return true;
    for (const s of document.styleSheets) {
      const node = s.ownerNode;
      if (node && !(node.classList && node.classList.contains('darkreader')) && node !== prepaint) return true;
    }
    return false;
  };
  const styled = () => {
    const body = document.body;
    if (!body) return false;
    if (document.readyState === 'complete') return true;
    if (body.scrollHeight < 32 || body.clientHeight < 32 || !hasStyle()) return false;
    for (const child of body.children) if (!/^(SCRIPT|STYLE|LINK)$/.test(child.tagName)) return true;
    return false;
  };

  const check = () => {
    wanted = choice();
    if (!wanted) { dropPrepaint(); releaseMark(); apply(false); send(); return; }
    if (forced()) { native = null; apply(true); return; }
    if (styled()) { native = isDarkOnItsOwn(); dropPrepaint(); }
    // Until the page can be looked at it stays on its dark ground (`prepaint`), never white: Dark Reader goes to work
    // only on a page that needs it, not first on every page with a dark look of its own too.
    else if (native === null) { putPrepaint(); send(); return; }
    apply(native !== true);
    send();
  };

  // MARK: Telling Zigzag

  const hex = (c) => '#' + [c.r, c.g, c.b].map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');
  const backgroundOf = (el) => {
    for (; el && el.nodeType === 1; el = el.parentElement) {
      const c = rgba(getComputedStyle(el).backgroundColor);
      if (c && c.a > 0.6) return c;
    }
    return null;
  };
  // The page's color as it's drawn now, for the bar above it.
  const colorOf = () => {
    const body = document.body;
    let c = body ? backgroundOf(body) : null;
    if (!c) c = darkened || native === true ? rgba(theme().darkSchemeBackgroundColor) : { r: 255, g: 255, b: 255, a: 1 };
    // A page dark on its own whose root and body paint white or nothing (a dark app laid over them): the dark at its
    // top, else its middle, which is what's seen under the bar (#134). Only a quiet dark, not a button's green.
    if (native === true && !darkened && lightness(c) >= 0.5 && body) {
      for (const [x, y] of [[0.5, 0.02], [0.5, 0.5]]) {
        const el = document.elementFromPoint(innerWidth * x, innerHeight * y);
        const under = el ? backgroundOf(el) : null;
        if (under && lightness(under) < 0.3 && Math.max(under.r, under.g, under.b) - Math.min(under.r, under.g, under.b) <= 48) { c = under; break; }
      }
    }
    return hex(c);
  };
  // Only the top page tells Zigzag; a frame's look is the page's business.
  const send = () => {
    if (!isTop) return;
    const message = { darkened, native: native === true, color: colorOf(), site };
    if (native === true && !darkened) { const mark = markNow(); if (mark !== undefined) message.marker = mark; }
    const key = JSON.stringify(message);
    if (key === lastSent) return;
    lastSent = key;
    try { window.webkit.messageHandlers.zigzagDark.postMessage(message); } catch (e) {}
  };

  // MARK: When to look

  let checkTimer = 0;
  const checkSoon = (delay) => {
    clearTimeout(checkTimer);
    checkTimer = setTimeout(check, delay);
  };
  // A theme switched on the page itself (a class or data-theme on the root or body) is looked at again; Dark Reader's
  // own marks on the root aren't.
  const themes = new MutationObserver(() => checkSoon(150));
  const themeAttributes = ['class', 'data-theme', 'data-color-mode', 'data-mode', 'data-bs-theme', 'data-color-scheme'];
  let watchedBody = null;
  const watchBody = () => {
    if (document.body && document.body !== watchedBody) {
      watchedBody = document.body;
      themes.observe(watchedBody, { attributes: true, attributeFilter: themeAttributes });
    }
  };
  // While the page comes in it's looked at just before each frame is drawn (`requestAnimationFrame` runs then), until
  // it has its style: the first look decides it in the frame its own colors would first show in.
  let decided = false;
  const beforeFrame = () => {
    if (decided) return;
    watchBody();
    if (!wanted || forced()) { decided = true; return; }
    if (styled()) { decided = true; check(); return; }
    requestAnimationFrame(beforeFrame);
  };

  // No white page first: a page starts on a dark ground until it's looked at, its site's own dark if it was last
  // seen dark (with its own dark mark), else the dark Dark Reader draws white as. A forced one is darkened at once.
  if (wanted && forced()) apply(true);
  else { if (wanted) { putPrepaint(); if (native === true) putMark(); } send(); }
  requestAnimationFrame(beforeFrame);
  if (document.documentElement) themes.observe(document.documentElement, { attributes: true, attributeFilter: themeAttributes });
  document.addEventListener('DOMContentLoaded', () => { watchBody(); if (!decided && styled()) { decided = true; check(); } });
  addEventListener('load', () => {
    decided = true;
    // A mark the site never touched isn't one its look uses now.
    if (markPut) setTimeout(() => { if (markPut) { releaseMark(); check(); } }, 2000);
    check();
    // An app that draws a light loading screen, then its own dark.
    setTimeout(check, 600);
    setTimeout(check, 2000);
  });
  addEventListener('pageshow', (e) => { if (e.persisted) check(); });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => checkSoon(100));

  window.__zigzagDark = {
    // Zigzag's choice changed (a setting, the site's own row, the Mac's appearance).
    set(config2) {
      const themeWas = JSON.stringify(config.theme);
      Object.assign(config, config2);
      // Pure black changed: drawn again with the new theme.
      if (darkened && JSON.stringify(config.theme) !== themeWas) DarkReader.enable(theme(), fix());
      check();
    },
    check,
    state: () => ({ wanted, darkened, native, color: colorOf(), engine: 'darkreader', forced: forced() }),
  };
})();
