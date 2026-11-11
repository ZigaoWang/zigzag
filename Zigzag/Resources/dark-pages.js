// Dark pages (Settings › Appearance): a light page is drawn dark, one that's already dark is left alone.
// Runs in Zigzag's own script world, in the main frame, from the start of the document. DarkPages.swift puts the
// choices in __CONFIG__: { on: default for sites without a choice, sitesOn, sitesOff, native: sites last seen
// already dark }.
//
// How: the whole page goes through one filter on the root (inverted, then its hues turned back), and pictures,
// video and the like are turned back again, so they look as they are. A filter on the root keeps fixed headers in
// place (it isn't a containing block there) and WebKit draws it on the GPU, so scrolling isn't touched. Whether a
// page is already dark is read from what it draws: the background under the page's middle, its body, and the
// color-scheme it declares.
(() => {
  if (window.__zigzagDark) return;
  const config = __CONFIG__;
  const type = document.contentType || '';
  // A picture, video or PDF opened on its own has nothing to darken.
  if (!/html|xml|text\/plain/.test(type)) return;
  // Web pages, files and Zigzag's own pages; an extension's own page is its own business.
  if (!/^(https?|file|about|zigzag):$/.test(location.protocol)) return;

  const siteOf = (host) => host.toLowerCase().replace(/^www\./, '');
  const matches = (site, list) => list.some((s) => site === s || site.endsWith('.' + s));
  const site = siteOf(location.hostname || '');
  const choice = () => (matches(site, config.sitesOn) ? true : matches(site, config.sitesOff) ? false : config.on);
  let wanted = choice();
  // null until the page has been looked at.
  let native = matches(site, config.native) ? true : null;
  let darkened = false;
  let lastSent = '';

  const imageMark = 'data-zigzag-dark-image';
  // Pictures and video, turned back. An SVG picture is usually a logo or icon drawn in the text's ink: it's left
  // darkened with the page, so a black logo doesn't vanish into the dark.
  const media = [
    'img:not([src$=".svg"]):not([src*=".svg?"])', 'video', 'canvas', 'embed', 'object', 'svg image',
    '[' + imageMark + ']', '[style*="background-image"][style*="url("]', '[style*="background:"][style*="url("]',
    // Video players and maps from elsewhere, framed in the page.
    'iframe[src*="youtube.com/embed"]', 'iframe[src*="youtube-nocookie.com"]', 'iframe[src*="player.vimeo.com"]',
    'iframe[src*="google.com/maps"]', 'iframe[src*="player.bilibili.com"]', 'iframe[src*="player.twitch.tv"]',
  ];
  const all = media.join(',');
  const css = `
    html { filter: invert(0.92) hue-rotate(180deg) !important; color-scheme: light !important; }
    :where(html) { background-color: #fff; }
    :is(${all}) { filter: invert(1) hue-rotate(180deg) !important; }
    :is(${all}) :is(${all}) { filter: none !important; }
  `;
  const style = document.createElement('style');
  style.setAttribute('data-zigzag-dark', '');

  const put = () => {
    const root = document.documentElement;
    if (root && style.parentNode !== root) root.appendChild(style);
  };
  const apply = (on) => {
    if (on === darkened) { if (on) put(); return; }
    darkened = on;
    if (on) { style.textContent = css; put(); scanSoon(document.documentElement); } else { style.textContent = ''; style.remove(); }
    send();
  };

  // MARK: Is the page already dark?

  const parse = (text) => {
    const m = /rgba?\(([^)]+)\)/.exec(text || '');
    if (!m) return null;
    const p = m[1].split(/[\s,/]+/).filter(Boolean).map(parseFloat);
    return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
  };
  const luminance = ([r, g, b]) => {
    const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
  };
  const prefersDark = () => matchMedia('(prefers-color-scheme: dark)').matches;
  // What's under the page when nothing paints a background: dark when the page says it's dark (color-scheme).
  const canvas = () => {
    const root = document.documentElement;
    const declared = getComputedStyle(root).colorScheme;
    const meta = document.querySelector('meta[name="color-scheme"]');
    const schemes = ((declared && declared !== 'normal' ? declared : meta && meta.content) || '').toLowerCase().split(/[\s,]+/);
    const dark = schemes.includes('dark') && (prefersDark() || !schemes.includes('light'));
    return dark ? [30, 30, 30, 1] : [255, 255, 255, 1];
  };
  const backgroundOf = (el) => {
    for (; el && el.nodeType === 1; el = el.parentElement) {
      const c = parse(getComputedStyle(el).backgroundColor);
      if (c && c[3] > 0.6) return c;
    }
    return canvas();
  };
  const skip = /^(IMG|VIDEO|CANVAS|IFRAME|EMBED|OBJECT|PICTURE|SVG)$/i;
  const isDark = (c) => luminance(c) < 0.2;
  // True when the page draws itself dark, false when light, null when there's no page to look at yet.
  const pageIsDark = () => {
    const body = document.body;
    if (!body) return null;
    const w = innerWidth, h = innerHeight;
    let dark = 0, light = 0;
    const count = (c, weight) => { if (isDark(c)) dark += weight; else light += weight; };
    count(backgroundOf(body), 2);
    for (const [x, y] of [[0.5, 0.5], [0.3, 0.3], [0.7, 0.3], [0.3, 0.7], [0.7, 0.7], [0.5, 0.15]]) {
      let el = document.elementFromPoint(w * x, h * y);
      while (el && el.parentElement && skip.test(el.tagName)) el = el.parentElement;
      if (el && el !== style) count(backgroundOf(el), 1);
    }
    // Light ink on the body is a dark theme's.
    const ink = parse(getComputedStyle(body).color);
    if (ink && luminance(ink) > 0.5) dark += 2;
    return dark > light;
  };

  const check = () => {
    wanted = choice();
    if (!wanted) { apply(false); return; }
    // Looked at as the page draws itself: our style forces a light color-scheme, which a page drawn with
    // light-dark() would follow. Off and on again in one go, so nothing is drawn in between.
    const sheet = darkened && style.sheet;
    if (sheet) sheet.disabled = true;
    const found = pageIsDark();
    if (sheet) sheet.disabled = false;
    if (found !== null) native = found;
    // Until the page can be looked at, a site last seen dark stays as it is and any other is darkened, so it
    // never comes up white first.
    apply(native !== true);
    send();
  };

  // MARK: Background pictures

  // An element showing a photo as its background (a hero, a card) turns back like a picture. Small ones are
  // icons, drawn in the text's ink, and stay darkened; so do the page's own body and anything holding a lot.
  let scanTimer = 0;
  const queue = new Set();
  const scanSoon = (root) => {
    if (!root || !darkened) return;
    queue.add(root);
    if (!scanTimer) scanTimer = setTimeout(scan, 120);
  };
  const scan = () => {
    scanTimer = 0;
    const roots = [...queue];
    queue.clear();
    if (!darkened) return;
    const started = performance.now();
    for (const root of roots) {
      if (!root.isConnected) continue;
      const list = root.nodeType === 1 ? [root, ...root.getElementsByTagName('*')] : [];
      for (const el of list) {
        if (el === document.documentElement || el === document.body || el.hasAttribute(imageMark)) continue;
        const image = getComputedStyle(el).backgroundImage;
        if (!image || image === 'none' || !image.includes('url(')) continue;
        const box = el.getBoundingClientRect();
        if (Math.min(box.width, box.height) < 40) continue;
        if (el.getElementsByTagName('*').length > 60) continue;
        el.setAttribute(imageMark, '');
      }
      // A huge page is looked at once, not again on every change.
      if (performance.now() - started > 60) break;
    }
  };

  // MARK: Telling Zigzag

  const colorOf = () => {
    // The page's color as it's drawn: its own, put through the filter when darkened.
    const c = document.body ? backgroundOf(document.body) : canvas();
    let [r, g, b] = c;
    if (darkened) {
      const k = 0.92;
      [r, g, b] = [r, g, b].map((v) => k * (255 - v) + (1 - k) * v);
      // hue-rotate(180deg) leaves gray alone and turns a color to its opposite; the page's background is nearly
      // always a gray, and anything else is close enough for the bar's tint.
      const mean = (r + g + b) / 3;
      [r, g, b] = [r, g, b].map((v) => Math.max(0, Math.min(255, 2 * mean - v)));
    }
    return '#' + [r, g, b].map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');
  };
  const send = () => {
    const message = { darkened, native: native === true, color: colorOf(), site };
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
  // Darkened from the first moment, unless the site was last seen dark: no white page first.
  if (wanted && native !== true) apply(true);
  // A theme switched on the page itself (a class or data-theme on the root or body) is looked at again.
  const themes = new MutationObserver(() => checkSoon(150));
  const watchThemes = (el) => themes.observe(el, { attributes: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode', 'data-mode'] });
  let watchedBody = null;
  // The root can be put back by a page that writes itself over (document.write), taking the style with it.
  new MutationObserver((records) => {
    if (darkened && style.parentNode !== document.documentElement) put();
    if (document.body && document.body !== watchedBody) { watchedBody = document.body; watchThemes(watchedBody); checkSoon(60); }
    if (!darkened) return;
    for (const r of records) {
      for (const node of r.addedNodes) {
        if (node.nodeType !== 1 || node === style) continue;
        if (node.tagName === 'LINK' || node.tagName === 'STYLE') checkSoon(100);
        else scanSoon(node);
      }
    }
  }).observe(document, { childList: true, subtree: true });
  if (document.documentElement) watchThemes(document.documentElement);
  document.addEventListener('DOMContentLoaded', () => check());
  addEventListener('load', () => { check(); setTimeout(check, 600); setTimeout(check, 2000); });
  addEventListener('pageshow', (e) => { if (e.persisted) check(); });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => checkSoon(100));

  window.__zigzagDark = {
    // Zigzag's choice changed (a setting, the site's own row, the Mac's appearance).
    set(config2) { Object.assign(config, config2); check(); },
    check,
    state: () => ({ wanted, darkened, native, color: colorOf() }),
  };
})();
