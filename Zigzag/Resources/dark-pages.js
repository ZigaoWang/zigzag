// Dark pages (Settings › Appearance): a light page is drawn dark, one that's already dark is left alone.
// Runs in Zigzag's own script world, in every frame, from the start of the document. DarkPages.swift puts the
// choices in `config` below: { on: default for sites without a choice, sitesOn, sitesOff, native: sites last seen
// already dark, black: Pure black backgrounds, strength: how far white is turned over, root, canvas, media: the
// style's parts, marks: the attributes it looks for, palette: the site's own dark palette if one was made, fill: a
// dark site's fill for its light parts if one was made, sitesForced: sites darkened even when dark, learn:
// whether one may be made here (never in a private window), paletteDelay }.
//
// A palette (#134): the first time a light site is seen, once it has loaded and the page is idle, its style sheets are
// read and its colors turned into a dark set (dark-palette.js, put in as `palette` below), as a style sheet Zigzag
// keeps for the site. From the next visit on that sheet is the page's look from its first frame: plain overrides of
// the site's own colors, with no filter, so pictures and video are simply left alone, and nothing watches the page.
// The first time a site is read, the palette is tried on the page there and then (in one go, so nothing is drawn in
// between): if it covers the page it takes over from the filter on that visit already, and if it doesn't the site keeps
// the filter, so no later visit starts with a palette that leaves the page light. A later visit drawn with a palette
// checks it covers the page as soon as there's a page to look at (its first frame, then as it finishes loading), and
// goes back to the filter at once if it doesn't. Later visits also check, when idle, whether the site's style changed,
// and read it again if so.
//
// White never shows first (#134): a page that's darkened starts so at document start (the filter, or the palette with
// its own dark ground), and one that isn't yet, since its site was last seen dark, starts on a plain dark ground
// (`prepaint`: a dark color-scheme and background on the root, the body clear) until it's looked at; then that goes,
// so a site dark on its own shows its own colors, and a light one is darkened.
//
// How: the whole page goes through one filter on the root (inverted, then its hues turned back), and pictures,
// video and the like are turned back again, so they look as they are. A filter on the root keeps fixed headers in
// place (it isn't a containing block there) and WebKit draws it on the GPU, so scrolling isn't touched. Whether a
// page is already dark is read from what it draws: the background under the page's middle, its body, and the
// color-scheme it declares.
//
// Frames: a frame's page says hello to the page around it, which turns that frame back and tells it whether dark
// pages are wanted (the top page's choice), so the frame darkens itself only if it's light: a light widget comes out
// dark and a dark video player as it is. A frame that never says hello (no script can run there) stays darkened with
// the page around it, as before. Shadow roots get the pictures' rules of their own, since the page's style doesn't
// reach inside them. Pictures that arrive later are looked at when the page is idle, never on every change.
(() => {
  if (window.__zigzagDark) return;
  const config = __CONFIG__;
  const palette = __PALETTE__;
  const marks = config.marks;
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
  // its own (about:blank, srcdoc) is part of the page around it, and darkened with it.
  if (!(isTop ? /^(https?|file|about|zigzag):$/ : /^(https?|file):$/).test(location.protocol)) { leftAlone(); return; }

  const siteOf = (host) => host.toLowerCase().replace(/^www\./, '');
  const matches = (site, list) => list.some((s) => site === s || site.endsWith('.' + s));
  const site = siteOf(location.hostname || '');
  // A frame follows the top page's choice, which the page around it passes on; nothing until then.
  let told = isTop ? null : false;
  // Whether this page knows its choice: the top page always, a frame once told.
  let heard = isTop;
  const choice = () => (!isTop ? told === true
    : matches(site, config.sitesOn) ? true : matches(site, config.sitesOff) ? false : config.on);
  let wanted = choice();
  // Force dark (the site panel, #134): darkened even when it looks dark on its own. The top page only.
  const forced = () => isTop && matches(site, config.sitesForced || []);
  // Whether the page is drawn dark: wanted, and light, or not looked at yet, or forced.
  const darkens = () => native !== true || forced();
  // null until the page has been looked at.
  let native = isTop && matches(site, config.native) ? true : null;
  let darkened = false;
  // Drawn by the site's palette rather than the filter.
  let usingPalette = false;
  // The palette left too much of this page light: the filter for the rest of this visit, unless trying it again
  // once the page is idle finds it covers the page after all.
  let refused = false;
  // Refused as the page came in, before it had settled: tried again once it has.
  let refusedEarly = false;
  // Nothing sent to Zigzag while a palette is tried on the page.
  let quiet = false;
  let lastSent = '';

  // Only the top page, and only the palette made for this site with these backgrounds.
  const paletteFits = () => isTop && !refused && !!config.palette && config.palette.origin === location.origin
    && config.palette.black === config.black && !config.palette.invert && !!config.palette.css;
  const css = () => (usingPalette ? config.palette.css + '\n' : config.root + (isTop ? config.canvas : '') + config.media);
  const style = document.createElement('style');
  style.setAttribute('data-zigzag-dark', '');
  // The plain dark ground a page starts on while it's not known whether it's dark on its own (`prepaint` in the header).
  const prepaint = document.createElement('style');
  prepaint.setAttribute('data-zigzag-dark', 'prepaint');
  prepaint.textContent = config.prepaint || '';
  const putPrepaint = () => {
    const root = document.documentElement;
    if (isTop && config.prepaint && root && prepaint.parentNode !== root) root.appendChild(prepaint);
  };
  const dropPrepaint = () => { if (prepaint.parentNode) prepaint.remove(); };

  // MARK: Shadow roots

  // One sheet shared by every open shadow root: the pictures' rules alone, empty while the page isn't darkened.
  const shadowRoots = new Set();
  let shadowSheet = null;
  try { shadowSheet = new CSSStyleSheet(); } catch (e) {}
  const shadowStyles = [];
  const shadowCSS = () => (darkened && !usingPalette ? config.media : '');
  const restyleShadows = () => {
    const text = shadowCSS();
    if (shadowSheet) { try { shadowSheet.replaceSync(text); } catch (e) {} }
    for (const s of shadowStyles) s.textContent = text;
  };
  const adopt = (root) => {
    if (shadowRoots.has(root)) return;
    shadowRoots.add(root);
    let adopted = false;
    if (shadowSheet) {
      try { root.adoptedStyleSheets = [...root.adoptedStyleSheets, shadowSheet]; adopted = true; } catch (e) {}
    }
    if (!adopted) {
      const s = document.createElement('style');
      s.textContent = shadowCSS();
      shadowStyles.push(s);
      root.appendChild(s);
    }
    added.observe(root, { childList: true, subtree: true });
    scanSoon(root);
  };

  const put = () => {
    const root = document.documentElement;
    if (root && style.parentNode !== root) root.appendChild(style);
  };
  const apply = (on) => {
    const how = on && paletteFits();
    if (on) dropPrepaint();
    if (on === darkened && how === usingPalette) { if (on) put(); return; }
    darkened = on;
    usingPalette = how;
    if (on) {
      style.textContent = css();
      put();
      if (!usingPalette) scanSoon(document.documentElement);
    } else { style.textContent = ''; style.remove(); }
    watch();
    restyleShadows();
    refreshFill();
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
    // Below a short body, the root with no background of its own: the body's color is the whole window's, as CSS
    // paints it, so a dark page with little on it isn't read as white there (#134).
    const body = document.body;
    const own = body && parse(getComputedStyle(body).backgroundColor);
    if (own && own[3] > 0.6) return own;
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
    // Not wanted here: said, so a bar colored after the last page's darkened look doesn't keep it.
    if (!wanted) { dropPrepaint(); apply(false); refreshFill(); send(); return; }
    // Looked at as the page draws itself: our style forces a light color-scheme, which a page drawn with
    // light-dark() would follow. Off and on again in one go, so nothing is drawn in between.
    const sheet = darkened && style.sheet;
    const ground = prepaint.parentNode && prepaint.sheet;
    const fill = fillStyle.parentNode && fillStyle.sheet;
    for (const s of [sheet, ground, fill]) if (s) s.disabled = true;
    const found = pageIsDark();
    for (const s of [sheet, ground, fill]) if (s) s.disabled = false;
    if (found !== null) { native = found; dropPrepaint(); }
    // Until the page can be looked at, a site last seen dark stays as it is and any other is darkened, so it
    // never comes up white first.
    apply(darkens());
    refreshFill();
    send();
  };

  // MARK: Pictures the selectors can't see

  // An element showing a photo as its background (a hero, a card, a ::before), and open shadow roots, found when
  // the page is idle: each element once, a slice at a time, so a long page never holds up scrolling or typing.
  // Icon-sized ones and SVG drawings are drawn in the text's ink and stay darkened; so does a repeating texture
  // behind a lot of the page.
  // A page WebKit isn't drawing (a tab in the background) may not get its idle callbacks at all, timeout or not: a
  // timer stands in once it's clearly late.
  const idle = (f) => {
    let ran = false;
    const run = (deadline) => { if (!ran) { ran = true; f(deadline); } };
    if (window.requestIdleCallback) requestIdleCallback(run, { timeout: 1000 });
    setTimeout(() => { const end = performance.now() + 12; run({ timeRemaining: () => end - performance.now() }); },
      window.requestIdleCallback ? 1500 : 120);
  };
  const seen = new WeakSet();
  const roots = [];
  let list = [], at = 0;
  let scanning = false;
  const scanSoon = (root) => {
    if (!root || !darkened || usingPalette) return;
    roots.push(root);
    if (!scanning) { scanning = true; idle(scan); }
  };
  const isIcon = (w, h) => w > 0 && h > 0 && w <= 24 && h <= 24;
  const drawingsOnly = (image) => {
    const urls = image.match(/url\([^)]*\)/g) || [];
    return urls.length > 0 && urls.every((u) => /svg/i.test(u));
  };
  const showsPicture = (s) => {
    const image = s.backgroundImage;
    return !!image && image !== 'none' && image.includes('url(') && !drawingsOnly(image);
  };
  const isTexture = (s) => !/no-repeat/.test(s.backgroundRepeat) && !/cover|contain/.test(s.backgroundSize);
  const look = (el) => {
    if (el.shadowRoot) adopt(el.shadowRoot);
    if (el === document.documentElement || el === document.body || el === style) return;
    if (!el.hasAttribute(marks.image)) {
      const s = getComputedStyle(el);
      if (showsPicture(s)) {
        const box = el.getBoundingClientRect();
        const big = isTexture(s) && el.getElementsByTagName('*').length > 60;
        if (!isIcon(box.width, box.height) && !big) el.setAttribute(marks.image, '');
      }
    }
    for (const [pseudo, mark] of [['::before', marks.before], ['::after', marks.after]]) {
      if (el.hasAttribute(mark)) continue;
      const s = getComputedStyle(el, pseudo);
      const content = s.content;
      if (!content || content === 'none' || content === 'normal') continue;
      const picture = (content.includes('url(') && !drawingsOnly(content))
        || (showsPicture(s) && !isIcon(parseFloat(s.width) || 0, parseFloat(s.height) || 0));
      if (picture) el.setAttribute(mark, '');
    }
  };
  const scan = (deadline) => {
    if (!darkened || usingPalette) { roots.length = 0; list = []; at = 0; scanning = false; return; }
    let n = 0;
    while (true) {
      if (at >= list.length) {
        if (!roots.length) break;
        const root = roots.shift();
        if (!root.isConnected) continue;
        const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
        list = root.nodeType === 1 ? [root, ...all] : [...all];
        at = 0;
      }
      const el = list[at++];
      if (seen.has(el)) continue;
      seen.add(el);
      if (el.isConnected) look(el);
      if (++n % 32 === 0 && deadline.timeRemaining() < 2) break;
    }
    if (at < list.length || roots.length) idle(scan); else { list = []; at = 0; scanning = false; }
  };
  // Shadow roots made after their element was looked at (a custom element defined late), once more as the page
  // finishes loading: their element is found again by its name, not by looking at every element.
  const waiting = new Set();
  const lateHosts = (root) => {
    if (!window.customElements || !customElements.whenDefined) return;
    for (const el of root.querySelectorAll(':not(:defined)')) {
      const name = el.localName;
      if (waiting.has(name) || !name.includes('-')) continue;
      waiting.add(name);
      customElements.whenDefined(name).then(() => {
        for (const scope of [document, ...shadowRoots]) {
          for (const host of scope.querySelectorAll(name)) if (host.shadowRoot) adopt(host.shadowRoot);
        }
      }).catch(() => {});
    }
  };

  // MARK: Frames

  const message = (data) => (data && typeof data === 'object' ? data.zigzagDark : undefined);
  // What a frame inside is told: whether it's wanted, and the style for it, never the lists of sites.
  const forFrames = () => ({ wanted, black: config.black, strength: config.strength, root: config.root, media: config.media });
  const frames = new Set();
  const asked = [];
  const tell = (win) => { try { win.postMessage({ zigzagDark: forFrames() }, '*'); } catch (e) {} };
  const frameOf = (source) => {
    for (const scope of [document, ...shadowRoots]) {
      for (const frame of scope.querySelectorAll('iframe')) if (frame.contentWindow === source) return frame;
    }
    return null;
  };
  const tellFrames = () => {
    for (const frame of frames) {
      if (!frame.isConnected) { frames.delete(frame); continue; }
      if (frame.contentWindow) tell(frame.contentWindow);
    }
  };
  addEventListener('message', (e) => {
    const source = e.source;
    if (!source || source === window) return;
    // From the page around this frame: Zigzag's choice for the top page.
    if (!isTop && source === window.parent) {
      const said = message(e.data);
      if (!said || typeof said !== 'object') return;
      told = said.wanted === true;
      heard = true;
      Object.assign(config, { black: said.black, strength: said.strength, root: said.root, media: said.media });
      if (darkened) style.textContent = css();
      restyleShadows();
      check();
      tellFrames();
      asked.splice(0).forEach(tell);
      return;
    }
    // A frame inside this page saying hello: it's turned back from now on and darkens itself.
    let parent = null;
    try { parent = source.parent; } catch (e2) { return; }
    if (parent !== window || message(e.data) !== 'hello') return;
    const frame = frameOf(source);
    if (!frame) return;
    if (!frame.hasAttribute(marks.frame)) frame.setAttribute(marks.frame, '');
    frames.add(frame);
    // A frame not yet told answers its own once it is.
    if (heard) tell(source); else asked.push(source);
  });
  if (!isTop) { try { window.parent.postMessage({ zigzagDark: 'hello' }, '*'); } catch (e) {} }

  // MARK: Telling Zigzag

  const colorOf = () => {
    // The page's color as it's drawn: its own, put through the filter when darkened.
    let c = document.body ? backgroundOf(document.body) : canvas();
    // A page dark on its own whose root and body paint white or nothing (a dark app laid over them): the dark at
    // its top, else its middle, which is what's seen under the bar (#134). Only a quiet dark, not a button's green.
    const calm = (k) => isDark(k) && Math.max(k[0], k[1], k[2]) - Math.min(k[0], k[1], k[2]) <= 48;
    if (native === true && !darkened && !isDark(c) && document.body) {
      for (const [x, y] of [[0.5, 0.02], [0.5, 0.5]]) {
        let el = document.elementFromPoint(innerWidth * x, innerHeight * y);
        while (el && el.parentElement && skip.test(el.tagName)) el = el.parentElement;
        const under = el && el !== style ? backgroundOf(el) : null;
        if (under && calm(under)) { c = under; break; }
      }
    }
    let [r, g, b] = c;
    if (darkened && !usingPalette) {
      const k = config.strength;
      [r, g, b] = [r, g, b].map((v) => k * (255 - v) + (1 - k) * v);
      // hue-rotate(180deg) leaves gray alone and turns a color to its opposite; the page's background is nearly
      // always a gray, and anything else is close enough for the bar's tint.
      const mean = (r + g + b) / 3;
      [r, g, b] = [r, g, b].map((v) => Math.max(0, Math.min(255, 2 * mean - v)));
    }
    return '#' + [r, g, b].map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');
  };
  // Only the top page tells Zigzag; a frame's look is the page's business.
  const send = () => {
    if (!isTop || quiet) return;
    const message = { darkened, native: native === true, color: colorOf(), site, palette: usingPalette };
    const key = JSON.stringify(message);
    if (key === lastSent) return;
    lastSent = key;
    try { window.webkit.messageHandlers.zigzagDark.postMessage(message); } catch (e) {}
  };

  // MARK: Palette

  // Only a top page on the web, in a profile that keeps things (never a private window).
  const learnable = () => isTop && config.learn === true && /^https?:$/.test(location.protocol);
  const ownSheet = (sheet) => {
    const node = sheet.ownerNode;
    return node === style || !!(node && node.hasAttribute && node.hasAttribute('data-zigzag-dark'));
  };
  // What the page's style is made of, cheaply: each sheet's address and how many rules it has, each <style>'s length.
  const pieces = () => {
    const out = [];
    for (const sheet of document.styleSheets) {
      if (ownSheet(sheet)) continue;
      if (sheet.href) {
        let n = '?';
        try { n = sheet.cssRules.length; } catch (e) {}
        out.push('h ' + sheet.href.split('#')[0] + ' ' + n);
      } else {
        const node = sheet.ownerNode;
        out.push('i ' + (node && node.textContent ? node.textContent.length : 0));
      }
    }
    const own = document.documentElement && document.documentElement.getAttribute('style');
    if (own) out.push('r ' + own.length);
    return out;
  };
  // How much of the page came out dark with the palette on: a grid of points, each one's background, and the ink
  // of the ones with text. True when nearly all of it did.
  const covered = () => {
    if (pageIsDark() !== true) return false;
    const w = innerWidth, h = innerHeight;
    let all = 0, bad = 0;
    for (let i = 1; i <= 4; i++) {
      for (let j = 1; j <= 4; j++) {
        let el = document.elementFromPoint((w * i) / 5, (h * j) / 5);
        while (el && el.parentElement && skip.test(el.tagName)) el = el.parentElement;
        if (!el) continue;
        all++;
        const bg = backgroundOf(el);
        if (luminance(bg) > 0.3) { bad++; continue; }
        const hasText = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
        const ink = hasText && parse(getComputedStyle(el).color);
        if (ink && palette.contrast(ink, bg) < 3) bad++;
      }
    }
    return bad <= Math.max(1, all * 0.15);
  };
  // The site's palette tried on the page as it is now, in place of the filter, all in one go so nothing is drawn in
  // between: kept if it covers the page, the filter back if it doesn't. True when it's kept.
  const tryPalette = () => {
    if (usingPalette) return true;
    if (!darkened) return false;
    quiet = true;
    refused = false;
    apply(true);
    const ok = usingPalette && covered();
    if (!ok) { refused = true; apply(true); }
    quiet = false;
    send();
    return ok;
  };
  // A palette from an earlier visit, looked at as soon as there's a page to look at (and again as it finishes
  // loading): a page it leaves light goes back to the filter now rather than once it's idle.
  const checkEarly = () => {
    if (!usingPalette || !document.body || !document.body.firstElementChild) return;
    if (!covered()) { refused = true; refusedEarly = true; apply(true); }
  };
  const firstFrame = () => {
    if (!usingPalette) return;
    if (document.body && document.body.firstElementChild) { checkEarly(); return; }
    requestAnimationFrame(firstFrame);
  };
  // A sheet from elsewhere that the page can't read (no CORS): Zigzag fetches its text, without cookies.
  const fetchRules = async (href) => {
    try {
      const text = await window.webkit.messageHandlers.zigzagDarkSheet.postMessage(href);
      if (typeof text !== 'string' || !text) return null;
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(text);
      return sheet.cssRules;
    } catch (e) { return null; }
  };
  const tellPalette = (message) => {
    try { window.webkit.messageHandlers.zigzagDark.postMessage(Object.assign({ kind: 'palette', black: config.black }, message)); } catch (e) {}
  };
  let analysis = null;
  // Reading the sheets takes no more than this much of the page's idle time, all told.
  const budget = 400;
  const maxColors = 20000;
  // The page's sheets, read into a palette's state; sheets from elsewhere it can't read are fetched by Zigzag.
  const readSheets = async (state) => {
    const lists = [];
    let fetched = 0, unread = 0;
    for (const sheet of [...document.styleSheets, ...(document.adoptedStyleSheets || [])]) {
      if (ownSheet(sheet) || sheet.disabled) continue;
      const media = sheet.media && sheet.media.mediaText;
      if (palette.skips(media)) continue;
      let rules = null;
      try { rules = sheet.cssRules; } catch (e) {}
      if (!rules && sheet.href && fetched < 16) { fetched++; rules = await fetchRules(sheet.href); }
      if (!rules) { unread++; continue; }
      lists.push([rules, media ? ['@media ' + media] : []]);
    }
    // Read in the page's order: the last added is read first.
    for (const [rules, media] of lists.reverse()) palette.add(state, rules, media);
    return { sheets: lists.length, fetched, unread };
  };
  // Work done in the page's idle time, a slice at a time, while `still()` holds and inside `limit` ms all told.
  // `work(more)` does a slice and says whether it's all done. Resolves with whether it finished, and the time taken.
  const inSlices = (work, still, limit) => new Promise((done) => {
    let busy = 0;
    const step = (deadline) => {
      if (!still()) { done({ finished: false, busy }); return; }
      const t0 = performance.now();
      // A few milliseconds each time even when the page says it has less to spare (it often does), and up to a
      // frame's worth when it has more.
      const over = work(() => { const t = performance.now() - t0; return t < 4 || (t < 16 && deadline.timeRemaining() > 1); });
      busy += performance.now() - t0;
      if (over) done({ finished: true, busy }); else if (busy > limit) done({ finished: false, busy }); else idle(step);
    };
    idle(step);
  });
  const analyse = async (fp) => {
    const began = performance.now();
    const state = palette.start();
    const { sheets, fetched, unread } = await readSheets(state);
    const read = await inSlices((more) => palette.collect(state, more), () => darkened, budget);
    const finished = read.finished;
    let busy = read.busy;
    if (!darkened) return;
    const t1 = performance.now();
    // Writing the sheet is done in one go: past this many colors it would hold the page up, and the sheet would be
    // too big to start every page with anyway.
    const decls = state.entries.reduce((n, e) => n + e.decls.length, 0);
    const made = finished && decls <= maxColors ? palette.generate(state, config.black) : null;
    const writing = performance.now() - t1;
    busy += writing;
    analysis = { ms: Math.round(busy * 10) / 10, writing: Math.round(writing * 10) / 10, wall: Math.round(performance.now() - began),
      rules: state.rules, colors: made ? made.colors : 0, declarations: decls, sheets, fetched, unread, finished };
    // Nothing to go on (too much to read, or no colors of its own): the filter, until the site's style changes.
    const useless = !made || made.colors === 0 || made.capped;
    // Tried on the page now: if it covers it, it takes over on this visit; if not, the site keeps the filter.
    let covers;
    if (!useless && darkened && !usingPalette) {
      const before = config.palette;
      config.palette = { origin: location.origin, black: config.black, css: made.rules.join('\n'), invert: false,
        fingerprints: [fp], verified: true };
      covers = tryPalette();
      refusedEarly = false;
      // Not covered: the filter stays (`refused`), and so does whatever palette the page started with.
      if (!covers) config.palette = before;
    }
    tellPalette({ fingerprint: fp, rules: useless ? [] : made.rules, invert: useless, stats: analysis, checked: covers });
  };
  let looked = false;
  const paletteSoon = () => {
    if (looked || !learnable()) return;
    looked = true;
    setTimeout(() => idle(() => {
      if (!darkened) return;
      const fp = palette.fingerprint(pieces());
      const p = config.palette;
      const known = p && p.origin === location.origin && p.black === config.black ? p : null;
      const seen = !!known && known.fingerprints.includes(fp);
      if (refusedEarly) {
        // Refused as it came in: tried once more now that the page has settled, and the site told either way.
        refusedEarly = false;
        const ok = tryPalette();
        if (seen) { tellPalette({ fingerprint: fp, verified: ok }); return; }
      } else if (usingPalette && (!seen || !known.verified)) {
        const ok = covered();
        if (!ok) { refused = true; apply(true); }
        if (seen) { tellPalette({ fingerprint: fp, verified: ok }); return; }
      }
      if (!seen) analyse(fp).catch((e) => { analysis = { error: String(e) }; });
    }), config.paletteDelay || 1200);
  };

  // MARK: Filling in a dark site

  // A site dark on its own can still draw some things light: a suggestion list, a dialog, a sheet's cells (#134). Its
  // style is read once, as a light site's is, for those alone (`generateFill` in dark-palette.js), and kept for the site
  // as its `fill`: a sheet that turns its light surfaces dark, and the ink and lines on them light, while its own dark
  // colors are left as they are. Something light added later (a suggestion list as you type) is covered as it comes,
  // since the sheet names it; a sheet the page adds later is read when the page has added one, after typing, and
  // on the next visit.
  const fillStyle = document.createElement('style');
  fillStyle.setAttribute('data-zigzag-dark', 'fill');
  const fillFits = () => isTop && !!config.fill && config.fill.origin === location.origin && config.fill.black === config.black
    && !config.fill.invert && !!config.fill.css;
  const filling = () => wanted && native === true && !darkened && !forced();
  const refreshFill = () => {
    const root = document.documentElement;
    if (filling() && fillFits() && root) {
      if (fillStyle.textContent !== config.fill.css) fillStyle.textContent = config.fill.css;
      if (fillStyle.parentNode !== root) root.appendChild(fillStyle);
    } else if (fillStyle.parentNode) fillStyle.remove();
  };
  // The page's answer for a selector: is what it declares dark already where it applies (the site's own dark look
  // overriding it)? Only the first element it matches is asked; one that matches nothing now is kept.
  const overridden = (candidate) => {
    for (const one of palette.splitList(candidate.selector)) {
      const [base, pseudo] = palette.pseudoOf(one);
      let el = null;
      try { el = document.querySelector(base); } catch (e) { continue; }
      if (!el) continue;
      const s = getComputedStyle(el, pseudo);
      const now = palette.parse(candidate.name.startsWith('--') ? s.getPropertyValue(candidate.name).trim() : s.backgroundColor);
      if (!now) return false;
      return candidate.kind === 'light' ? !palette.isLightSurface(now) : !palette.isDarkInk(now);
    }
    return false;
  };
  let fillBusy = false;
  let fillRuns = 0;
  let fillAnalysis = null;
  const fillBudget = 300;
  const analyseFill = async (fp) => {
    const began = performance.now();
    const state = palette.start();
    const { sheets, fetched, unread } = await readSheets(state);
    const read = await inSlices((more) => palette.collect(state, more), filling, budget);
    if (!filling()) return;
    // Asked of the page in slices too: each is a selector looked up.
    const candidates = read.finished ? palette.fillCandidates(state) : [];
    const rejected = new Set();
    let at = 0;
    const asked = await inSlices((more) => {
      while (at < candidates.length) {
        const c = candidates[at++];
        if (overridden(c)) rejected.add(c.key);
        if (at % 16 === 0 && !more()) return false;
      }
      return true;
    }, filling, fillBudget);
    if (!filling()) return;
    const t1 = performance.now();
    const made = read.finished && asked.finished ? palette.generateFill(state, config.black, rejected) : null;
    const writing = performance.now() - t1;
    const useless = !made || made.colors === 0 || made.capped;
    fillAnalysis = { ms: Math.round((read.busy + asked.busy + writing) * 10) / 10, wall: Math.round(performance.now() - began),
      rules: state.rules, colors: made ? made.colors : 0, candidates: candidates.length, rejected: rejected.size, sheets, fetched, unread,
      finished: read.finished && asked.finished };
    if (!useless) {
      // Drawn at once, with what was kept for the site's other pages before.
      const known = config.fill && config.fill.origin === location.origin && config.fill.black === config.black && !config.fill.invert ? config.fill : null;
      const css = (known ? known.css + '\n' : '') + made.rules.join('\n');
      config.fill = { origin: location.origin, black: config.black, css, invert: false, fingerprints: [...(known ? known.fingerprints : []), fp] };
      refreshFill();
    }
    tellPalette({ fill: true, fingerprint: fp, rules: useless ? [] : made.rules, invert: useless, stats: fillAnalysis });
  };
  // Read the site's style for its fill, if it's one not read before.
  const fillLook = () => {
    // A few times a visit at most: a page that keeps adding style as it runs isn't read over and over (#89).
    if (fillBusy || fillRuns >= 3 || !learnable() || !filling()) return;
    const fp = palette.fingerprint(pieces());
    const p = config.fill;
    if (p && p.origin === location.origin && p.black === config.black && p.fingerprints.includes(fp)) return;
    fillBusy = true;
    fillRuns++;
    analyseFill(fp).catch((e) => { fillAnalysis = { error: String(e) }; }).finally(() => { fillBusy = false; });
  };
  let fillTimer = 0;
  const fillSoon = (delay) => {
    if (!learnable()) return;
    clearTimeout(fillTimer);
    fillTimer = setTimeout(() => idle(fillLook), delay);
  };
  // A sheet added to the head later, and the sheets a page loads as you type into it (a suggestion list's own).
  let typed = 0;
  if (isTop) {
    addEventListener('input', () => { if (typed < 8 && filling()) { typed++; fillSoon(1500); } }, true);
    const heads = new MutationObserver((records) => {
      if (!filling()) return;
      for (const r of records) for (const n of r.addedNodes) if (n.tagName === 'LINK' || n.tagName === 'STYLE') { fillSoon(1000); return; }
    });
    document.addEventListener('DOMContentLoaded', () => { if (document.head) heads.observe(document.head, { childList: true }); });
  }

  // MARK: When to look

  let checkTimer = 0;
  const checkSoon = (delay) => {
    clearTimeout(checkTimer);
    checkTimer = setTimeout(check, delay);
  };
  // A theme switched on the page itself (a class or data-theme on the root or body) is looked at again.
  const themes = new MutationObserver(() => checkSoon(150));
  const watchThemes = (el) => themes.observe(el, { attributes: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode', 'data-mode'] });
  let watchedBody = null;
  let watchedRoot = null;
  // New elements, in the page and in its shadow roots: only noted here, looked at when idle. Drawn by a palette or
  // not darkened, only the root and the body arriving (or the root put back) are watched, not every change.
  let watching = '';
  const added = new MutationObserver((records) => {
    if (darkened && style.parentNode !== document.documentElement) put();
    const root = document.documentElement;
    if (watching === 'top' && root && root !== watchedRoot) { watchedRoot = root; added.observe(root, { childList: true }); }
    if (document.body && document.body !== watchedBody) { watchedBody = document.body; watchThemes(watchedBody); checkSoon(60); }
    if (!darkened || usingPalette) return;
    for (const r of records) {
      for (const node of r.addedNodes) {
        if (node.nodeType !== 1 || node === style) continue;
        if (node.tagName === 'LINK' || node.tagName === 'STYLE') checkSoon(100);
        else scanSoon(node);
      }
    }
  });
  const watch = () => {
    const want = darkened && !usingPalette ? 'all' : 'top';
    if (want === watching) return;
    watching = want;
    added.disconnect();
    watchedRoot = null;
    if (want === 'all') {
      added.observe(document, { childList: true, subtree: true });
      for (const root of shadowRoots) added.observe(root, { childList: true, subtree: true });
    } else {
      // The root can be put back by a page that writes itself over (document.write), taking the style with it.
      added.observe(document, { childList: true });
      if (document.documentElement) { watchedRoot = document.documentElement; added.observe(watchedRoot, { childList: true }); }
    }
  };
  // Darkened from the first moment, unless the site was last seen dark: no white page first. One last seen dark
  // starts on the plain dark ground until it's looked at.
  if (wanted && darkens()) apply(true);
  else { if (wanted) { putPrepaint(); refreshFill(); } send(); }
  if (usingPalette) requestAnimationFrame(firstFrame);
  watch();
  if (document.documentElement) watchThemes(document.documentElement);
  document.addEventListener('DOMContentLoaded', () => { check(); checkEarly(); });
  addEventListener('load', () => {
    check();
    checkEarly();
    setTimeout(check, 600);
    setTimeout(check, 2000);
    if (darkened && !usingPalette) idle(() => { try { lateHosts(document); } catch (e) {} });
    paletteSoon();
    fillSoon(config.paletteDelay || 1200);
  });
  addEventListener('pageshow', (e) => { if (e.persisted) check(); });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => checkSoon(100));

  window.__zigzagDark = {
    // Zigzag's choice changed (a setting, the site's own row, the Mac's appearance).
    set(config2) {
      Object.assign(config, config2);
      if (darkened) {
        const was = usingPalette;
        usingPalette = paletteFits();
        style.textContent = css();
        watch();
        if (was && !usingPalette) scanSoon(document.documentElement);
      }
      restyleShadows();
      check();
      tellFrames();
    },
    check,
    state: () => ({ wanted, darkened, native, color: colorOf(), frames: frames.size, shadowRoots: shadowRoots.size,
      palette: usingPalette, refused, analysis, fill: !!fillStyle.parentNode, fillAnalysis }),
  };
})();
