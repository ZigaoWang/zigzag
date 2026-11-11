// Dark pages' palette (#134): a light site's own colors turned into a dark set, once, as plain CSS. DarkPages.swift puts
// this into dark-pages.js as its `palette`; it's one expression, so tests can run it in JavaScriptCore as it is.
//
// The colors are read from the site's style sheets (custom properties first: most sites theme through them) and each
// is mapped in OKLCH by what it colors: a surface goes onto a dark ramp, text is flipped and kept readable (WCAG AA)
// against the surfaces, an accent keeps its hue and chroma. The result is a style sheet of overrides on the selectors
// that declared each color, so pictures, video and drawing are never touched. Nothing here looks at the page itself:
// `collect` takes rules shaped like the CSSOM's, everything else takes plain values.
(() => {
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

  // MARK: Colors

  // [r, g, b, a] with r, g, b in 0...255 and a in 0...1.
  const named = {
    white: [255, 255, 255, 1], black: [0, 0, 0, 1], transparent: [0, 0, 0, 0], red: [255, 0, 0, 1], green: [0, 128, 0, 1],
    blue: [0, 0, 255, 1], gray: [128, 128, 128, 1], grey: [128, 128, 128, 1], silver: [192, 192, 192, 1],
    whitesmoke: [245, 245, 245, 1], gainsboro: [220, 220, 220, 1], lightgray: [211, 211, 211, 1], lightgrey: [211, 211, 211, 1],
    darkgray: [169, 169, 169, 1], darkgrey: [169, 169, 169, 1], dimgray: [105, 105, 105, 1], dimgrey: [105, 105, 105, 1],
    snow: [255, 250, 250, 1], ivory: [255, 255, 240, 1], beige: [245, 245, 220, 1], linen: [250, 240, 230, 1],
    aliceblue: [240, 248, 255, 1], ghostwhite: [248, 248, 255, 1], floralwhite: [255, 250, 240, 1], navy: [0, 0, 128, 1],
    maroon: [128, 0, 0, 1], purple: [128, 0, 128, 1], orange: [255, 165, 0, 1], yellow: [255, 255, 0, 1],
  };
  const unit = (s, scale) => (s.endsWith('%') ? (parseFloat(s) / 100) * scale : parseFloat(s));
  const hue = (s) => {
    const v = parseFloat(s);
    return /turn$/.test(s) ? v * 360 : /rad$/.test(s) ? (v * 180) / Math.PI : /grad$/.test(s) ? v * 0.9 : v;
  };
  const hslToRgb = (h, s, l) => {
    h = ((h % 360) + 360) % 360;
    const k = (n) => (n + h / 30) % 12;
    const a = s * Math.min(l, 1 - l);
    const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
    return [f(0) * 255, f(8) * 255, f(4) * 255];
  };
  const rgbToHsl = ([r, g, b]) => {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2;
    if (max === min) return [0, 0, l];
    const d = max - min, s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    const h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    return [h * 60, s, l];
  };
  // The parts of a color function: "255 255 255 / 0.5" or "255, 255, 255, 0.5".
  const parts = (inner) => inner.trim().split(/\s*[,/]\s*|\s+/).filter(Boolean);
  // A color written any of the common ways, or null (var(), currentcolor, a keyword, a syntax it doesn't know).
  const parse = (text) => {
    if (typeof text !== 'string') return null;
    const s = text.trim().toLowerCase();
    if (!s) return null;
    if (s[0] === '#') {
      const h = s.slice(1);
      if (!/^[0-9a-f]+$/.test(h)) return null;
      if (h.length === 3 || h.length === 4) {
        const v = [...h].map((c) => parseInt(c + c, 16));
        return [v[0], v[1], v[2], h.length === 4 ? v[3] / 255 : 1];
      }
      if (h.length === 6 || h.length === 8) {
        const v = [0, 2, 4, 6].map((i) => parseInt(h.slice(i, i + 2), 16));
        return [v[0], v[1], v[2], h.length === 8 ? v[3] / 255 : 1];
      }
      return null;
    }
    const m = /^(rgba?|hsla?)\(([^()]*)\)$/.exec(s);
    if (m) {
      const p = parts(m[2]);
      if (p.length < 3 || p.some((x) => x === 'none' || !/^[-+.\d]/.test(x))) return null;
      const a = p.length > 3 ? clamp(unit(p[3], 1), 0, 1) : 1;
      if (m[1].startsWith('rgb')) return [clamp(unit(p[0], 255), 0, 255), clamp(unit(p[1], 255), 0, 255), clamp(unit(p[2], 255), 0, 255), a];
      const [r, g, b] = hslToRgb(hue(p[0]), clamp(unit(p[1], 1), 0, 1), clamp(unit(p[2], 1), 0, 1));
      return [r, g, b, a];
    }
    return named[s] ? named[s].slice() : null;
  };
  const hex2 = (v) => Math.round(clamp(v, 0, 255)).toString(16).padStart(2, '0');
  const format = ([r, g, b, a]) => (a >= 0.999 ? '#' + hex2(r) + hex2(g) + hex2(b)
    : `rgba(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)}, ${Math.round(a * 1000) / 1000})`);

  // MARK: OKLCH

  const toLinear = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  const fromLinear = (c) => 255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055);
  // [L, C, H]: L 0...1, C from 0 (gray) up, H in degrees.
  const toOklch = ([r, g, b]) => {
    const R = toLinear(r), G = toLinear(g), B = toLinear(b);
    const l = Math.cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B);
    const m = Math.cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B);
    const s = Math.cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B);
    const L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
    const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
    const Bb = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
    const C = Math.hypot(A, Bb);
    return [L, C, C < 1e-6 ? 0 : ((Math.atan2(Bb, A) * 180) / Math.PI + 360) % 360];
  };
  const oklchToLinear = (L, C, H) => {
    const A = C * Math.cos((H * Math.PI) / 180), B = C * Math.sin((H * Math.PI) / 180);
    const l = Math.pow(L + 0.3963377774 * A + 0.2158037573 * B, 3);
    const m = Math.pow(L - 0.1055613458 * A - 0.0638541728 * B, 3);
    const s = Math.pow(L - 0.0894841775 * A - 1.291485548 * B, 3);
    return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s];
  };
  const inGamut = (rgb) => rgb.every((v) => v >= -0.0005 && v <= 1.0005);
  // Back to sRGB, with chroma taken down until it fits (hue and lightness kept).
  const fromOklch = (L, C, H) => {
    L = clamp(L, 0, 1);
    let lin = oklchToLinear(L, C, H);
    if (!inGamut(lin)) {
      let lo = 0, hi = C;
      for (let i = 0; i < 14; i++) {
        const mid = (lo + hi) / 2;
        if (inGamut(oklchToLinear(L, mid, H))) lo = mid; else hi = mid;
      }
      lin = oklchToLinear(L, lo, H);
    }
    return lin.map((v) => clamp(fromLinear(clamp(v, 0, 1)), 0, 255));
  };

  // MARK: Contrast

  const luminance = ([r, g, b]) => 0.2126 * toLinear(r) + 0.7152 * toLinear(g) + 0.0722 * toLinear(b);
  const over = ([r, g, b, a], [br, bg, bb]) => [r * a + br * (1 - a), g * a + bg * (1 - a), b * a + bb * (1 - a), 1];
  // WCAG 2 contrast ratio, 1...21; a see-through color is taken as drawn over `bg`.
  const contrast = (fg, bg) => {
    const a = luminance(fg.length > 3 && fg[3] < 1 ? over(fg, bg) : fg), b = luminance(bg);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  };

  // MARK: Mapping

  // The neutral ramp: the page's own white becomes `low`, its light grays climb toward `high` (raised surfaces).
  const ramps = {
    dark: { low: [18, 18, 18], high: [30, 30, 30] },
    black: { low: [0, 0, 0], high: [17, 17, 17] },
  };
  const ramp = (black) => {
    const r = black ? ramps.black : ramps.dark;
    return { low: r.low, high: r.high, lowL: toOklch(r.low)[0], highL: toOklch(r.high)[0] };
  };
  const neutral = 0.03;
  // Where a surface of lightness L goes on the ramp: white at the bottom, light grays up to the raised end, mid grays
  // a little above, and a surface the page already drew dark (a footer, a tooltip) stays as dark as it was.
  const surfaceL = (L, r) => {
    if (L >= 0.82) return r.lowL + ((1 - L) / 0.18) * (r.highL - r.lowL);
    if (L >= 0.6) return r.highL + ((0.82 - L) / 0.22) * (0.42 - r.highL);
    return Math.min(L, 0.42);
  };
  // Text light enough to read on the ramp's raised end, and so on its lower end too; stepped up until it is.
  const legible = (L, C, H, a, r, target) => {
    let rgb = fromOklch(L, C, H);
    for (let l = L; l <= 1.0001 && contrast([...rgb, a], r.high) < target; l += 0.02) rgb = fromOklch(l, C, H);
    return rgb;
  };
  const roles = ['background', 'text', 'border', 'fill'];
  const map = (color, role, black) => {
    const [r0, g0, b0, a] = color;
    if (a === 0) return color.slice();
    const r = ramp(black);
    const [L, C, H] = toOklch([r0, g0, b0]);
    let rgb;
    if (role === 'background') {
      if (a < 0.3 && C < neutral) {
        // A faint tint (a hover, a stripe): black over white becomes white over black.
        rgb = fromOklch(1 - L, C, H);
      } else if (C >= 0.08 && L < 0.8) {
        // An accent (a button, a badge): its own hue and chroma, no brighter than text on it can bear.
        rgb = fromOklch(Math.min(L, 0.5), C, H);
      } else if (C >= neutral) {
        // A pale tint (a notice, a highlighted row): dark, with a little of its hue.
        rgb = fromOklch(surfaceL(L, r) + 0.03, Math.min(C * 0.6, 0.06), H);
      } else if (L >= 0.995 || L <= r.lowL) {
        rgb = L >= 0.995 ? r.low.slice() : [r0, g0, b0];
      } else {
        rgb = fromOklch(surfaceL(L, r), C, H);
      }
    } else if (role === 'border') {
      if (C >= 0.08) rgb = fromOklch(Math.max(L, 0.55), C, H);
      else if (L >= 0.6) rgb = fromOklch(0.27 + (1 - L) * 0.5, Math.min(C, 0.04), H);
      else rgb = fromOklch(Math.max(0.47, 0.8 - L * 0.5), C, H);
    } else {
      // Text and drawn icons: light already stays (it sits on a dark or colored surface), dark is turned over, and
      // both are kept readable. Icons need 3:1, text 4.5:1 (AA).
      const target = role === 'fill' ? 3 : 4.5;
      const l = L >= 0.65 ? L : 0.93 - L * 0.35;
      rgb = legible(l, C, H, a, r, target);
    }
    return [rgb[0], rgb[1], rgb[2], a];
  };

  // Every color in a value (a gradient's stops, a shorthand's), each mapped; a value that shows a picture is left as it
  // is (its colors are in the picture). Null when nothing in it changes.
  const colorWord = new RegExp('#[0-9a-f]{3,8}\\b|(?:rgba?|hsla?)\\([^()]*\\)|\\b(?:' + Object.keys(named).join('|') + ')\\b', 'gi');
  const rewrite = (value, role, black) => {
    if (typeof value !== 'string' || /url\(/i.test(value) || /^\s*(inherit|initial|unset|revert|currentcolor)\s*$/i.test(value)) return null;
    let changed = false;
    const out = value.replace(colorWord, (word, offset) => {
      // Not a name inside something else: var(--white), a font called White.
      const before = value.slice(Math.max(0, offset - 2), offset);
      if (/[-\w]$/.test(before) && word[0] !== '#') return word;
      const c = parse(word);
      if (!c || c[3] === 0) return word;
      changed = true;
      return format(map(c, role, black));
    });
    return changed ? out : null;
  };

  // MARK: Selectors

  // Overrides beat the page's own rules wherever they're read from, and keep their own order: every one is !important
  // and one id stronger. A pseudo-element stays at the end, where it has to be.
  const boostMark = ':not(#zigzag-dark)';
  const splitList = (selector) => {
    const out = [];
    let depth = 0, start = 0, quote = '';
    for (let i = 0; i < selector.length; i++) {
      const ch = selector[i];
      if (quote) { if (ch === '\\') i++; else if (ch === quote) quote = ''; continue; }
      if (ch === '"' || ch === "'") quote = ch;
      else if (ch === '(' || ch === '[') depth++;
      else if (ch === ')' || ch === ']') depth--;
      else if (ch === ',' && depth === 0) { out.push(selector.slice(start, i).trim()); start = i + 1; }
    }
    out.push(selector.slice(start).trim());
    return out.filter(Boolean);
  };
  const pseudoElement = /(::[\w-]+(\([^()]*\))?(:[\w-]+)*|:(before|after|first-line|first-letter))$/i;
  const boost = (selector) => splitList(selector).map((one) => {
    const m = pseudoElement.exec(one);
    return m ? one.slice(0, m.index) + boostMark + m[0] : one + boostMark;
  }).join(', ');

  // MARK: Reading the sheets

  // What each property colors; anything else isn't looked at.
  const roleOf = {
    'background-color': 'background', 'background-image': 'background',
    color: 'text', '-webkit-text-fill-color': 'text', 'caret-color': 'text', 'text-decoration-color': 'text',
    'border-top-color': 'border', 'border-right-color': 'border', 'border-bottom-color': 'border', 'border-left-color': 'border',
    'border-block-start-color': 'border', 'border-block-end-color': 'border', 'border-inline-start-color': 'border',
    'border-inline-end-color': 'border', 'outline-color': 'border', 'column-rule-color': 'border',
    fill: 'fill', stroke: 'fill',
  };
  // Rules inside these never apply to a light page shown dark, or are dark already.
  const skippedMedia = /prefers-color-scheme|forced-colors|^\s*print\b|inverted-colors/i;
  const varRef = /var\(\s*(--[\w-]+)/g;
  const triplet = /^\s*-?[\d.]+(deg|turn|rad)?%?\s*,?\s+-?[\d.]+%?\s*,?\s+-?[\d.]+%?\s*$/;

  // Reads rules (a sheet's cssRules, or rules shaped like them) into what `generate` needs, a slice at a time:
  // `state` carries on where it stopped, and `more()` says whether there's time left. Returns true when done.
  const start = () => ({ stack: [], entries: [], uses: {}, values: {}, rules: 0, capped: false });
  const add = (state, rules, media) => { if (rules && rules.length) state.stack.push({ rules, at: 0, media }); };
  const maxRules = 60000;
  const shorthands = [['background', 'background'], ['border', 'border'], ['border-color', 'border'], ['border-top', 'border'],
    ['border-bottom', 'border'], ['border-left', 'border'], ['border-right', 'border'], ['outline', 'border']];
  // Each custom property a value reads, counted for what it colors, and whether it's channels (rgb(var(--x))).
  const used = (state, value, role) => {
    for (const m of value.matchAll(varRef)) {
      const use = (state.uses[m[1]] = state.uses[m[1]] || {});
      use[role] = (use[role] || 0) + 1;
      const fn = /(rgba?|hsla?)\(\s*$/i.exec(value.slice(0, m.index));
      if (fn) use.fn = fn[1].toLowerCase().startsWith('hsl') ? 'hsl' : 'rgb';
    }
  };
  const collect = (state, more) => {
    let n = 0;
    while (state.stack.length) {
      if (++n % 64 === 0 && !more()) return false;
      const top = state.stack[state.stack.length - 1];
      if (top.at >= top.rules.length) { state.stack.pop(); continue; }
      const rule = top.rules[top.at++];
      if (!rule) continue;
      if (++state.rules > maxRules) { state.capped = true; state.stack.length = 0; break; }
      const media = top.media;
      if (typeof rule.selectorText === 'string' && rule.style) {
        const style = rule.style, decls = [];
        let pending = false;
        for (let i = 0; i < style.length; i++) {
          const name = style[i];
          const custom = name.startsWith('--');
          if (!custom && !roleOf[name]) continue;
          const value = style.getPropertyValue(name);
          // A shorthand written with var(): its parts read as nothing, the shorthand has the text.
          if (!value) { pending = true; continue; }
          if (custom) {
            const v = value.trim();
            (state.values[name] = state.values[name] || new Set()).add(v);
            decls.push([name, v]);
            // One property set from another: whatever colors the one colors the other.
            for (const m of v.matchAll(varRef)) (state.uses[m[1]] = state.uses[m[1]] || {})['=' + name] = 1;
          } else {
            decls.push([name, value]);
            used(state, value, roleOf[name]);
          }
        }
        if (pending) {
          for (const [short, role] of shorthands) {
            const value = style.getPropertyValue(short);
            if (value && value.includes('var(')) used(state, value, role);
          }
        }
        if (decls.length) state.entries.push({ selector: rule.selectorText, media, decls });
        continue;
      }
      if (rule.styleSheet) {
        // @import: its sheet in place, if it can be read.
        let rules = null;
        try { rules = rule.styleSheet.cssRules; } catch (e) {}
        const text = rule.media && rule.media.mediaText;
        if (!(text && skippedMedia.test(text))) add(state, rules, text ? media.concat('@media ' + text) : media);
        continue;
      }
      if (!rule.cssRules) continue;
      let wrap = null;
      if (rule.media && typeof rule.media.mediaText === 'string') {
        if (skippedMedia.test(rule.media.mediaText)) continue;
        wrap = '@media ' + rule.media.mediaText;
      } else if (rule.type === 12 && rule.conditionText) {
        wrap = '@supports ' + rule.conditionText;
      } else if (rule.containerQuery !== undefined || (rule.conditionText && rule.containerName !== undefined)) {
        wrap = '@container ' + ((rule.containerName || '') + ' ' + (rule.containerQuery || rule.conditionText)).trim();
      } else if (typeof rule.name === 'string' && rule.type === 0) {
        wrap = '';
      } else {
        // Keyframes, font faces, pages, scopes: nothing to override there.
        continue;
      }
      add(state, rule.cssRules, wrap ? media.concat(wrap) : media);
    }
    return true;
  };

  // What a custom property colors: what it's used for most, else what its name says, else how light it is.
  const roleByName = (name) => (/(^|-)(bg|background|surface|canvas|fill-color|backdrop|overlay|base|paper|page|body-bg)(-|$)/.test(name) ? 'background'
    : /(^|-)(fg|text|foreground|ink|font|heading|link|title|copy|label)(-|$)/.test(name) ? 'text'
    : /(^|-)(border|divider|line|outline|stroke|separator|rule)(-|$)/.test(name) ? 'border' : null);
  const varRoles = (state) => {
    const settled = {};
    const resolve = (name, seen) => {
      if (settled[name]) return settled[name];
      if (seen.has(name)) return null;
      seen.add(name);
      const use = state.uses[name] || {};
      const counts = { background: use.background || 0, text: use.text || 0, border: use.border || 0, fill: use.fill || 0 };
      for (const key of Object.keys(use)) {
        if (key[0] !== '=') continue;
        const role = resolve(key.slice(1), seen);
        if (role) counts[role] += 1;
      }
      let best = null, tie = false;
      for (const role of roles) {
        if (counts[role] <= 0) continue;
        if (!best || counts[role] > counts[best]) { best = role; tie = false; } else if (counts[role] === counts[best]) tie = true;
      }
      // Used as much for one thing as another: its name or its lightness decides.
      if (tie) return null;
      if (best) settled[name] = best;
      return best;
    };
    for (const name of Object.keys(state.values)) resolve(name, new Set());
    return settled;
  };

  // MARK: Writing the sheet

  // The overrides, as separate rules (custom properties first, then the rest, each in its @media as it was), and what
  // was found. `black` picks the ramp.
  const generate = (state, black) => {
    const settled = varRoles(state);
    const fns = {};
    for (const name of Object.keys(state.uses)) if (state.uses[name].fn) fns[name] = state.uses[name].fn;
    const memo = new Map();
    const mapped = (c, role) => {
      const key = role + c.join(',');
      if (!memo.has(key)) memo.set(key, map(c, role, black));
      return memo.get(key);
    };
    // A property's own value, if it only ever has one plain color: used where a rule uses it for something else.
    const single = (name) => {
      const values = state.values[name];
      if (!values || values.size !== 1) return null;
      return parse([...values][0]);
    };
    const roleFor = (name, value, c) => settled[name] || roleByName(name.toLowerCase())
      || (luminance(c) > 0.4 ? 'background' : 'text');
    const vars = [], rest = [];
    let colors = 0;
    for (const entry of state.entries) {
      const varDecls = [], decls = [];
      for (const [name, value] of entry.decls) {
        if (name.startsWith('--')) {
          const c = parse(value);
          if (c) {
            if (c[3] === 0) continue;
            varDecls.push(`${name}: ${format(mapped(c, roleFor(name, value, c)))} !important`);
            colors++;
            continue;
          }
          // Channels for rgb(var(--x)) or hsl(var(--x)): "255 255 255" or "210 40% 98%".
          if (fns[name] && triplet.test(value)) {
            const p = parts(value);
            const sep = value.includes(',') ? ', ' : ' ';
            const rgb = fns[name] === 'hsl' ? hslToRgb(hue(p[0]), clamp(unit(p[1], 1), 0, 1), clamp(unit(p[2], 1), 0, 1))
              : [unit(p[0], 255), unit(p[1], 255), unit(p[2], 255)];
            const c2 = [...rgb.map((v) => clamp(v, 0, 255)), 1];
            const m = mapped(c2, roleFor(name, value, c2));
            const out = fns[name] === 'hsl'
              ? (([h, s, l]) => `${Math.round(h * 10) / 10}${sep}${Math.round(s * 1000) / 10}%${sep}${Math.round(l * 1000) / 10}%`)(rgbToHsl(m.slice(0, 3).map(Math.round)))
              : m.slice(0, 3).map(Math.round).join(sep);
            varDecls.push(`${name}: ${out} !important`);
            colors++;
          }
          continue;
        }
        const role = roleOf[name];
        let out = null;
        const ref = /^\s*var\(\s*(--[\w-]+)\s*\)\s*$/.exec(value);
        if (ref) {
          // Used for something other than what it's mostly for: this use gets its own color.
          const c = single(ref[1]);
          if (c && c[3] > 0 && (settled[ref[1]] || roleByName(ref[1])) && (settled[ref[1]] || roleByName(ref[1])) !== role) out = format(mapped(c, role));
        } else if (!value.includes('var(')) {
          const c = name === 'background-image' ? null : parse(value);
          out = c ? (c[3] === 0 ? null : format(mapped(c, role))) : rewrite(value, role, black);
        }
        if (out) { decls.push(`${name}: ${out} !important`); colors++; }
      }
      const wrap = (body) => entry.media.reduceRight((inner, at) => `${at} { ${inner} }`, body);
      if (varDecls.length) vars.push(wrap(`${boost(entry.selector)} { ${varDecls.join('; ')} }`));
      if (decls.length) rest.push(wrap(`${boost(entry.selector)} { ${decls.join('; ')} }`));
    }
    const r = ramp(black);
    // The page itself: dark under everything, light ink where the page names none, and its own controls dark.
    const base = `:where(html) { background-color: ${format([...r.low, 1])}; color: ${format(map([0, 0, 0, 1], 'text', black))}; color-scheme: dark !important; }`;
    return { rules: [base, ...vars, ...rest], colors, rules_read: state.rules, capped: state.capped };
  };

  // MARK: Fingerprint

  // FNV-1a over what the page's style is made of (each sheet's address and size, its own style's length), so a later
  // visit can tell whether there's anything new to read without reading it.
  const fingerprint = (pieces) => {
    let h = 0x811c9dc5;
    const text = pieces.join('\n');
    for (let i = 0; i < text.length; i++) {
      h ^= text.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h.toString(16).padStart(8, '0') + ':' + pieces.length;
  };

  const skips = (mediaText) => !!mediaText && skippedMedia.test(mediaText);

  return { skips, parse, format, toOklch, fromOklch, luminance, contrast, map, rewrite, boost, splitList, ramp, start, add, collect, generate, fingerprint, roleOf };
})()
