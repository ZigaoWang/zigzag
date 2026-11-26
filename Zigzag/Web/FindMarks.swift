import AppKit
import WebKit

/// Find in page shows every match at once (#244): each one marked on the page, the one you're on stronger, and a tick
/// for each along the page's right edge, as Chrome does.
///
/// WebKit's own find (`PageFind`) still goes from match to match and says the count, so "3 of 28" stays the count
/// it marks. A script of Zigzag's own, in Zigzag's isolated world (`.defaultClient`, never the page's), finds the
/// same text and marks it with the CSS Custom Highlight API, which paints over text without touching the page's DOM.
/// Text WebKit won't paint a highlight on (a button's, a flex box's) gets a box in a layer of its own instead.
/// The highlight colors come from a user style sheet the page can't see or outrank. The match WebKit lands on is
/// told by the selection it makes, which the script then folds to a caret, so the stronger color shows instead of a
/// gray selection; it is selected again just before the next find, which goes on from it.
@MainActor
enum FindMarks {
    /// What the page has marked.
    struct Snapshot: Equatable {
        /// Where each match is, from 0 at the top of the page to 1 at the bottom, in page order. At most `maxMarks`.
        var marks: [Double]
        /// The match you're on, from 0, if it's one of `marks`.
        var current: Int?
        /// How many the script found: past `maxMarks`, `maxMarks + 1`.
        var count: Int
        /// The page is dark, so its marks are drawn for a dark page.
        var dark: Bool

        static let empty = Snapshot(marks: [], current: nil, count: 0, dark: false)

        init(marks: [Double], current: Int?, count: Int, dark: Bool) {
            self.marks = marks
            self.current = current
            self.count = count
            self.dark = dark
        }

        /// From the script's answer; nil if it isn't one.
        init?(_ value: Any?) {
            guard let body = value as? [String: Any], let marks = body["marks"] as? [Any] else { return nil }
            self.marks = marks.compactMap { ($0 as? NSNumber)?.doubleValue }.map { min(max($0, 0), 1) }
            let current = (body["current"] as? NSNumber)?.intValue ?? -1
            self.current = self.marks.indices.contains(current) ? current : nil
            count = (body["count"] as? NSNumber)?.intValue ?? self.marks.count
            dark = (body["dark"] as? Bool) ?? false
        }
    }

    /// Marked up to this many, as many as are counted: past it, the count says "More than 1,000 matches".
    static let maxMarks = PageFind.maxCount

    private static let styleSheetClass: AnyClass? = NSClassFromString("_WKUserStyleSheet")
    private static let styleSheetInit = NSSelectorFromString("initWithSource:forMainFrameOnly:")
    private static let addStyleSheet = NSSelectorFromString("_addUserStyleSheet:")

    /// Whether this WebKit lets Zigzag give pages the highlight colors. Without it, find is as before: WebKit's
    /// own mark on the one match.
    static var isAvailable: Bool {
        guard PageFind.isAvailable, let styleSheetClass, class_getInstanceMethod(styleSheetClass, styleSheetInit) != nil else { return false }
        return WKUserContentController.instancesRespond(to: addStyleSheet)
    }

    /// The highlights' names: made up anew each launch, with nothing in them that says Zigzag, so a page can't look
    /// for them by name.
    struct Names: Equatable {
        let all: String, current: String, allDark: String, currentDark: String

        static func random() -> Names {
            // No "i", so a name can never spell "find" or "zigzag" by chance.
            let letters = Array("abcdefghjklmnopqrstuvwxyz")
            let stem = "h" + String((0..<12).map { _ in letters.randomElement()! })
            return Names(all: stem + "a", current: stem + "c", allDark: stem + "ad", currentDark: stem + "cd")
        }
    }

    static let names = Names.random()

    /// Matches in a soft yellow (an amber on a dark page), the one you're on in a stronger orange. Above anything a
    /// page says: a user sheet's `!important` outranks the page's own. The page's text keeps its color (WebKit doesn't
    /// take a highlight's `color` from a user sheet), so on a dark page the orange is a deep one its light text reads on.
    static func css(_ names: Names) -> String {
        """
        ::highlight(\(names.all)) { background-color: \(colors.all) !important; }
        ::highlight(\(names.current)) { background-color: \(colors.current) !important; }
        ::highlight(\(names.allDark)) { background-color: \(colors.allDark) !important; }
        ::highlight(\(names.currentDark)) { background-color: \(colors.currentDark) !important; }
        """
    }

    static let colors = (all: "rgba(255, 214, 10, 0.42)", current: "rgb(255, 150, 20)", allDark: "rgba(255, 176, 32, 0.34)", currentDark: "rgb(204, 102, 0)")

    /// The tick colors, the highlights' own made solid enough to see on a scroll bar.
    static func tickColor(current: Bool, dark: Bool) -> NSColor {
        switch (current, dark) {
        case (false, false): NSColor(srgbRed: 0.95, green: 0.74, blue: 0.0, alpha: 1)
        case (true, false): NSColor(srgbRed: 1.0, green: 0.48, blue: 0.0, alpha: 1)
        case (false, true): NSColor(srgbRed: 0.86, green: 0.62, blue: 0.12, alpha: 1)
        case (true, true): NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
        }
    }

    /// The controllers that already have the colors.
    private static let styled = NSHashTable<WKUserContentController>.weakObjects()

    /// Gives the pages of this web view the highlight colors, and Zigzag's script a way to say the page changed.
    static func install(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        guard isAvailable, !styled.contains(controller), let styleSheetClass,
              let method = class_getInstanceMethod(styleSheetClass, styleSheetInit),
              let allocated = (styleSheetClass as AnyObject).perform(NSSelectorFromString("alloc")) else { return }
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, NSString, Bool) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(method_getImplementation(method), to: Init.self)
        guard let sheet = initialize(allocated, styleSheetInit, css(names) as NSString, false)?.takeRetainedValue() else { return }
        controller.perform(addStyleSheet, with: sheet)
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: .defaultClient)
        controller.add(Messages.shared, contentWorld: .defaultClient, name: messageName)
        styled.add(controller)
    }

    static let messageName = "zigzagFindMarks"

    /// Who hears of a page's marks changing by themselves (the page changed, or its size did).
    private static let listeners = NSMapTable<WKWebView, Listener>.weakToStrongObjects()
    private final class Listener {
        let changed: (Snapshot) -> Void
        init(_ changed: @escaping (Snapshot) -> Void) { self.changed = changed }
    }

    static func listen(to webView: WKWebView, _ changed: ((Snapshot) -> Void)?) {
        if let changed { listeners.setObject(Listener(changed), forKey: webView) } else { listeners.removeObject(forKey: webView) }
    }

    private final class Messages: NSObject, WKScriptMessageHandler {
        static let shared = Messages()
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard message.frameInfo.isMainFrame, let webView = message.webView, let snapshot = Snapshot(message.body) else { return }
                FindMarks.listeners.object(forKey: webView)?.changed(snapshot)
            }
        }
    }

    // MARK: The page's side

    private static func run(_ call: String, _ arguments: [String: Any], in webView: WKWebView) async -> Any? {
        try? await webView.runOwnScript(script + "\nreturn globalThis.__zigzagFind." + call + ";", asFunction: true, arguments: arguments)
    }

    /// Marks every match of `query`, and the one WebKit's find just selected as the one you're on. `paused`: you're
    /// in another window, so the page's changes aren't followed yet (`pause`).
    static func mark(_ query: String, in webView: WKWebView, paused: Bool = false) async -> Snapshot? {
        install(in: webView)
        let colors = ["all": colors.all, "current": colors.current, "allDark": colors.allDark, "currentDark": colors.currentDark]
        return Snapshot(await run("mark(query, names, colors, paused)", ["query": query, "names": namesArgument, "colors": colors, "paused": paused], in: webView))
    }

    /// Before going to the next match: the find starts from the match you're on, either way.
    static func prepare(in webView: WKWebView) async {
        _ = await run("prepare()", [:], in: webView)
    }

    /// A tick clicked: the next find starts from the match before it, so it lands on it.
    static func moveCaret(toMatch index: Int, in webView: WKWebView) async {
        _ = await run("caretTo(index)", ["index": index], in: webView)
    }

    /// The window isn't the one you're in: the page's changes aren't watched until it is again, and then it's looked
    /// at once.
    static func pause(_ paused: Bool, in webView: WKWebView) {
        webView.runOwnScript("if (globalThis.__zigzagFind) globalThis.__zigzagFind.pause(paused); return 0", asFunction: true, arguments: ["paused": paused])
    }

    /// Takes every mark off the page.
    static func clear(in webView: WKWebView) {
        listen(to: webView, nil)
        webView.runOwnScript("if (globalThis.__zigzagFind) globalThis.__zigzagFind.clear(); return 0", asFunction: true)
    }

    private static var namesArgument: [String: String] {
        ["all": names.all, "current": names.current, "allDark": names.allDark, "currentDark": names.currentDark]
    }

    // MARK: Ticks

    /// Each tick's place in a strip `height` tall: centered on its match's place along the track (the strip less
    /// `trackInset` at each end, clear of the page's rounded corners), on the screen's pixels. The one you're on last,
    /// so it's drawn over its neighbors.
    static func tickRects(_ snapshot: Snapshot, height: CGFloat, width: CGFloat, scale: CGFloat) -> [(index: Int, rect: CGRect)] {
        let track = height - trackInset * 2
        guard track > tickHeight, !snapshot.marks.isEmpty else { return [] }
        let scale = max(scale, 1)
        func place(_ i: Int) -> (Int, CGRect) {
            let center = trackInset + snapshot.marks[i] * (track - tickHeight) + tickHeight / 2
            let y = ((center - tickHeight / 2) * scale).rounded() / scale
            return (i, CGRect(x: tickInset, y: y, width: width - tickInset * 2, height: tickHeight))
        }
        var rects = snapshot.marks.indices.filter { $0 != snapshot.current }.map(place)
        if let current = snapshot.current { rects.append(place(current)) }
        return rects
    }

    /// The match whose tick is under `y`, the nearest if ticks crowd, within a few points.
    static func tick(at y: CGFloat, in rects: [(index: Int, rect: CGRect)]) -> Int? {
        let near = rects.filter { $0.rect.minY - tickReach <= y && y <= $0.rect.maxY + tickReach }
        return near.min { abs($0.rect.midY - y) < abs($1.rect.midY - y) }?.index
    }

    static let stripWidth: CGFloat = 12
    static let tickHeight: CGFloat = 2
    static let tickInset: CGFloat = 3
    /// Clear of the page card's corners (up to the window's 16pt curve), which would cut a tick at either end.
    static let trackInset: CGFloat = 8
    /// How far from a tick a click still takes it.
    static let tickReach: CGFloat = 3

    // MARK: The script

    /// Runs in Zigzag's world, defined once per page: what it keeps (the matches, the one you're on) lasts between
    /// calls and goes with the page.
    static let script = #"""
    if (!globalThis.__zigzagFind || globalThis.__zigzagFind.version !== 2) {
      const MAX = 1000;
      // Never searched: not text on screen, or only fallback content.
      const SKIP = new Set(['head', 'script', 'style', 'noscript', 'template', 'textarea', 'select', 'option', 'datalist',
        'canvas', 'video', 'audio', 'object', 'embed', 'img', 'picture', 'input']);
      const F = {
        version: 2, query: '', index: null, ranges: [], count: 0, current: null, docs: [], names: null, colors: null,
        caret: null, observers: [], timer: 0, firstWait: 0, rebuild: false, said: '', lastLook: 0, gap: 1000, paused: false,
        looks: 0, layers: new Map(), placing: 0, gone: 0, soon: false,
      };
      const isSpace = (code) => code === 32 || code === 9 || code === 10 || code === 13 || code === 12 || code === 160;
      // Lowercased one character at a time, so every place in the text still stands for one character of the page.
      const fold = (s) => {
        const lower = s.toLowerCase();
        if (lower.length === s.length) return lower;
        let out = '';
        for (const c of s) { const l = c.toLowerCase(); out += l.length === c.length ? l : c; }
        return out;
      };
      const normalized = (q) => {
        let out = '', space = false;
        const f = fold(q);
        for (let i = 0; i < f.length; i++) {
          if (isSpace(f.charCodeAt(i))) { if (!space) out += ' '; space = true; } else { out += f[i]; space = false; }
        }
        return out;
      };

      // The page's shown text, in the order it's shown, with where each character came from. Blocks, line breaks and
      // frames stand apart; runs of spaces are one, as they're drawn.
      const build = () => {
        const chars = [], nodes = [], offsets = [], texts = [], docs = [];
        let space = true;
        const boundary = () => {
          if (chars.length && chars[chars.length - 1] !== '\n') { chars.push('\n'); nodes.push(-1); offsets.push(0); }
          space = true;
        };
        const addText = (t) => {
          const s = t.data;
          if (!s) return;
          const f = fold(s);
          const n = texts.length;
          texts.push(t);
          for (let i = 0; i < s.length; i++) {
            if (isSpace(s.charCodeAt(i))) {
              if (space) continue;
              space = true;
              chars.push(' ');
            } else {
              space = false;
              chars.push(f[i]);
            }
            nodes.push(n); offsets.push(i);
          }
        };
        const children = (parent, visible) => { for (let c = parent.firstChild; c; c = c.nextSibling) visit(c, visible); };
        const visit = (node, visible) => {
          if (node.nodeType === 3) { if (visible) addText(node); return; }
          if (node.nodeType !== 1) return;
          const tag = node.localName;
          if (SKIP.has(tag)) return;
          const view = node.ownerDocument.defaultView;
          if (!view) return;
          const style = view.getComputedStyle(node);
          const display = style.display;
          if (display === 'none') return;
          // Folded away until found (Wikipedia's closed sections): WebKit's find counts it and opens it, so it's searched.
          if (style.contentVisibility === 'hidden' && node.getAttribute('hidden') !== 'until-found') return;
          if (tag === 'br') { boundary(); return; }
          const shown = style.visibility === 'visible';
          const inline = display === 'inline' || display === 'contents';
          if (!inline) boundary();
          if (tag === 'iframe' || tag === 'frame') {
            let doc = null;
            try { doc = node.contentDocument; } catch (e) {}
            if (doc && doc.documentElement) visitDocument(doc);
          } else if (tag === 'slot') {
            const assigned = node.assignedNodes({ flatten: true });
            if (assigned.length) { for (const n of assigned) visit(n, shown); } else children(node, shown);
          } else if (tag === 'details' && !node.open) {
            for (let c = node.firstElementChild; c; c = c.nextElementSibling) if (c.localName === 'summary') { visit(c, shown); break; }
          } else {
            children(node.shadowRoot || node, shown);
          }
          if (!inline) boundary();
        };
        const visitDocument = (doc) => {
          docs.push(doc);
          boundary();
          visit(doc.documentElement, true);
          boundary();
        };
        visitDocument(document);
        return { text: chars.join(''), nodes, offsets, texts, docs };
      };

      const search = () => {
        F.ranges = []; F.count = 0; F.gone = 0;
        const q = normalized(F.query);
        if (!q.trim()) return;
        if (!F.index) F.index = build();
        const { text, nodes, offsets, texts } = F.index;
        let from = 0;
        for (;;) {
          const at = text.indexOf(q, from);
          if (at < 0) break;
          from = at + q.length;
          const last = at + q.length - 1;
          if (nodes[at] < 0 || nodes[last] < 0) continue;
          if (++F.count > MAX) break;
          try {
            const start = texts[nodes[at]], end = texts[nodes[last]];
            const range = start.ownerDocument.createRange();
            range.setStart(start, offsets[at]);
            range.setEnd(end, offsets[last] + 1);
            F.ranges.push(range);
          } catch (e) { F.count--; }
        }
      };

      const overlaps = (a, b) => {
        try {
          if (a.startContainer.ownerDocument !== b.startContainer.ownerDocument) return false;
          return a.compareBoundaryPoints(Range.START_TO_END, b) === 1 && a.compareBoundaryPoints(Range.END_TO_START, b) === -1;
        } catch (e) { return false; }
      };
      const indexOf = (range) => range ? F.ranges.findIndex((r) => overlaps(r, range)) : -1;

      const color = (value) => {
        const m = /rgba?\(([^)]*)\)/.exec(value || '');
        if (!m) return null;
        const p = m[1].split(/[\s,\/]+/).filter(Boolean).map(parseFloat);
        return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
      };
      const light = (c) => (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255;
      const isDark = (doc) => {
        const view = doc.defaultView;
        if (!view) return false;
        for (const el of [doc.body, doc.documentElement]) {
          if (!el) continue;
          const bg = color(view.getComputedStyle(el).backgroundColor);
          if (bg && bg.a > 0.5) return light(bg) < 0.4;
        }
        const text = doc.body && color(view.getComputedStyle(doc.body).color);
        return !!text && light(text) > 0.6;
      };

      const unpaint = (doc) => {
        const registry = doc.defaultView && doc.defaultView.CSS && doc.defaultView.CSS.highlights;
        if (!registry || !F.names) return;
        for (const name of Object.values(F.names)) registry.delete(name);
      };
      // WebKit paints no highlight on text in an anonymous box (#329): text right in a button, a flex, grid or table
      // box, columns, or beside a block. Unselectable text gets it on the wrong words. Those are boxed instead.
      const unpaintable = (text, cache) => {
        let el = text.assignedSlot || text.parentNode;
        if (el && el.nodeType === 11) el = el.host;
        if (!el || el.nodeType !== 1) return false;
        if (cache.has(el)) return cache.get(el);
        const view = el.ownerDocument.defaultView;
        let style = view.getComputedStyle(el), box = el;
        if (style.webkitUserSelect === 'none' || style.userSelect === 'none') { cache.set(el, true); return true; }
        while (style.display === 'contents' && box.parentElement) { box = box.parentElement; style = view.getComputedStyle(box); }
        const display = style.display;
        let anonymous = box.localName === 'button' || /flex|grid|table|ruby/.test(display) && !/table-(cell|caption)/.test(display)
          || style.columnCount !== 'auto' || style.columnWidth !== 'auto';
        if (!anonymous && !display.startsWith('inline')) {
          for (let c = box.firstElementChild; c; c = c.nextElementSibling) {
            const s = view.getComputedStyle(c);
            if (s.float !== 'none' || s.position === 'absolute' || s.position === 'fixed') continue;
            if (s.display !== 'none' && s.display !== 'contents' && !s.display.startsWith('inline')) { anonymous = true; break; }
          }
        }
        cache.set(el, anonymous);
        return anonymous;
      };

      // A layer of boxes under a closed shadow root, there only while a match needs one. Multiplied on a light page and
      // screened on a dark one, so the text keeps its color; no z-index, which would keep it from blending.
      const HOST = { all: 'initial', display: 'block', position: 'absolute', left: '0', top: '0', width: '0', height: '0',
        overflow: 'visible', 'pointer-events': 'none', 'z-index': 'auto' };
      const place = (layer) => {
        const { host, root, ranges, current, dark } = layer;
        const origin = host.getBoundingClientRect();
        const boxes = [];
        for (const range of ranges) {
          const color = range === current ? (dark ? F.colors.currentDark : F.colors.current) : (dark ? F.colors.allDark : F.colors.all);
          for (const rect of range.getClientRects()) {
            if (!rect.width || !rect.height) continue;
            const b = host.ownerDocument.createElement('div');
            const s = b.style;
            s.position = 'absolute'; s.left = (rect.left - origin.left) + 'px'; s.top = (rect.top - origin.top) + 'px';
            s.width = rect.width + 'px'; s.height = rect.height + 'px'; s.background = color; s.mixBlendMode = dark ? 'screen' : 'multiply';
            // Readable where the page's own isolation keeps the box from blending.
            if (range === current) s.opacity = '0.65';
            boxes.push(b);
          }
        }
        root.replaceChildren(...boxes);
      };
      // Boxes in a scrolled box, or a fixed or sticky one, follow it; the page's own scrolling carries the rest.
      const moved = (event) => {
        if (F.placing || event.target.nodeType === 9 && ![...F.layers.values()].some((l) => l.pinned)) return;
        F.placing = requestAnimationFrame(() => { F.placing = 0; for (const layer of F.layers.values()) place(layer); });
      };
      const unbox = (doc) => {
        const layer = F.layers.get(doc);
        if (!layer) return;
        layer.host.remove();
        doc.removeEventListener('scroll', moved, true);
        F.layers.delete(doc);
      };
      const pinned = (el, cache) => {
        const seen = [];
        let result = false;
        for (let e = el; e; e = e.parentElement) {
          if (cache.has(e)) { result = cache.get(e); break; }
          seen.push(e);
          const position = e.ownerDocument.defaultView.getComputedStyle(e).position;
          if (position === 'fixed' || position === 'sticky') { result = true; break; }
        }
        for (const e of seen) cache.set(e, result);
        return result;
      };
      const box = (doc, ranges, current, dark) => {
        if (!ranges.length || !doc.documentElement) { unbox(doc); return; }
        let layer = F.layers.get(doc);
        if (!layer || !layer.host.isConnected) {
          unbox(doc);
          const host = doc.createElement(F.names.all + '-m');
          for (const [k, v] of Object.entries(HOST)) host.style.setProperty(k, v, 'important');
          layer = { host, root: host.attachShadow({ mode: 'closed' }) };
          doc.documentElement.appendChild(host);
          doc.addEventListener('scroll', moved, { capture: true, passive: true });
          F.layers.set(doc, layer);
        }
        const cache = new Map();
        Object.assign(layer, { ranges, current, dark, pinned: ranges.some((r) => pinned(r.startContainer.parentElement, cache)) });
        place(layer);
      };

      const paint = () => {
        const current = F.current !== null ? F.ranges[F.current] : null;
        const cache = new Map();
        for (const doc of [...F.layers.keys()]) if (!F.docs.includes(doc)) unbox(doc);
        for (const doc of F.docs) {
          const view = doc.defaultView;
          if (!view) continue;
          unpaint(doc);
          const dark = isDark(doc);
          const mine = [], boxed = [];
          for (const r of F.ranges) {
            // A match whose text the page took away: WebKit would paint its highlight on whatever comes before.
            if (r.collapsed || r.startContainer.ownerDocument !== doc) continue;
            if (unpaintable(r.startContainer, cache) || unpaintable(r.endContainer, cache)) boxed.push(r);
            // The one you're on only in its own highlight, so the soft color never tints the strong one.
            else if (r !== current) mine.push(r);
          }
          box(doc, boxed, current, dark);
          if (!view.CSS || !view.CSS.highlights || !view.Highlight) continue;
          if (mine.length) {
            const all = new view.Highlight(...mine);
            all.priority = 1000;
            view.CSS.highlights.set(dark ? F.names.allDark : F.names.all, all);
          }
          if (current && !current.collapsed && current.startContainer.ownerDocument === doc && !boxed.includes(current)) {
            const one = new view.Highlight(current);
            one.priority = 1001;
            view.CSS.highlights.set(dark ? F.names.currentDark : F.names.current, one);
          }
        }
      };

      // Where each match is, from the top of the page (0) to its bottom (1), as a scroll bar shows the page. A page
      // that doesn't scroll: where on screen.
      const marks = () => {
        const root = document.scrollingElement || document.documentElement;
        const height = Math.max(root.scrollHeight, 1), view = Math.max(innerHeight, 1);
        const scrolls = height > view + 1;
        const offsets = new Map();
        const offset = (doc) => {
          if (offsets.has(doc)) return offsets.get(doc);
          let y = 0, w = doc.defaultView;
          try {
            while (w && w !== window) {
              const frame = w.frameElement;
              if (!frame) { y = null; break; }
              y += frame.getBoundingClientRect().top + frame.clientTop;
              w = w.parent;
            }
          } catch (e) { y = null; }
          offsets.set(doc, y);
          return y;
        };
        return F.ranges.map((r) => {
          const rect = r.getBoundingClientRect();
          const y = rect.top + rect.height / 2 + (offset(r.startContainer.ownerDocument) || 0);
          const place = scrolls ? (y + scrollY) / height : y / view;
          return Math.min(Math.max(place, 0), 1);
        });
      };

      const snapshot = () => ({ marks: marks(), current: F.current === null ? -1 : F.current, count: F.count, dark: isDark(document) });

      // Said to Zigzag only when it's not what Zigzag last heard: a page that changes without moving a match says nothing.
      const post = () => {
        const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.zigzagFindMarks;
        if (!handler || !F.query) return;
        const now = snapshot(), said = JSON.stringify(now);
        if (said === F.said) return;
        F.said = said;
        handler.postMessage(now);
      };

      // The page changed: looked at again once it settles, a quarter second later. A page that keeps changing (a
      // clock, a live chat, a video's time) is looked at less and less often, down to every three seconds, until it
      // has been calm for a while.
      const SETTLE = 250, CALM = 5000, SLOWEST = 3000;
      const changed = (rebuild, lost) => {
        if (rebuild) F.index = null;
        F.rebuild = F.rebuild || rebuild;
        clearTimeout(F.timer);
        const now = Date.now();
        if (!F.firstWait) F.firstWait = now;
        const next = F.lastLook + F.gap;
        // Waited a whole gap since the first change: looked at as soon as the gap since the last look allows.
        let wait = now - F.firstWait >= F.gap ? Math.max(0, next - now) : Math.max(SETTLE, next - now);
        // A match the page drew again is found again soon, busy page or not, up to once a second.
        F.soon = F.soon || !!lost;
        if (F.soon) wait = Math.min(wait, Math.max(SETTLE, F.lastLook + 1000 - now));
        F.timer = setTimeout(look, wait);
      };
      const look = () => {
        F.timer = 0;
        F.soon = false;
        F.firstWait = 0;
        if (!F.query) return;
        const now = Date.now();
        F.gap = now - F.lastLook < CALM ? Math.min(F.gap + 1000, SLOWEST) : 1000;
        F.lastLook = now;
        if (F.rebuild) {
          F.looks++;
          const was = F.current !== null ? F.ranges[F.current] : null;
          search();
          const i = indexOf(was);
          F.current = i >= 0 ? i : null;
          paint();
        }
        F.rebuild = false;
        post();
      };

      // Only a change to the text can change the matches: a node with text added or taken away, or text edited
      // (not a script's or style's). A details opened or something unhidden can show text there was. A class
      // changing, which busy pages do all the time, is left alone: one that shows or hides text (an accordion, Show more)
      // changes the page's size, and that's looked at again, as calmly as any change.
      const QUIET = new Set(['script', 'style', 'noscript', 'template']);
      const hasText = (node) => (node.nodeType === 3 || node.nodeType === 1) && !QUIET.has(node.localName) && /\S/.test(node.textContent || '');
      const touchesText = (records) => records.some((r) => {
        if (r.type === 'attributes') return true;
        if (r.type === 'characterData') { const parent = r.target.parentNode; return !parent || !QUIET.has(parent.localName); }
        for (const n of r.addedNodes) if (hasText(n)) return true;
        for (const n of r.removedNodes) if (hasText(n)) return true;
        return false;
      });

      // While the window isn't the one you're in, nothing is watched; coming back, the page is looked at once. (A tab
      // that isn't shown has no find bar: the bar goes with its tab, and its marks with it.)
      const observe = () => {
        if (F.observers.length || F.paused) return;
        for (const doc of F.docs) {
          const view = doc.defaultView;
          if (!view) continue;
          const mutations = new view.MutationObserver((records) => {
            if (!touchesText(records)) return;
            // Matches taken away come off at once, not at the next look.
            let gone = 0;
            for (const r of F.ranges) if (r.collapsed) gone++;
            const lost = gone > F.gone;
            if (lost) { F.gone = gone; paint(); }
            changed(true, lost);
          });
          mutations.observe(doc, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['hidden', 'open'] });
          F.observers.push(mutations);
        }
        // Measured now, so the observer's first report (the size as it is) is told from a change made before it came.
        const root = document.documentElement;
        const measure = () => { const r = root.getBoundingClientRect(); return r.width + 'x' + r.height; };
        let size = measure();
        const sizes = new ResizeObserver(() => { const now = measure(); if (now !== size) { size = now; changed(true); } });
        sizes.observe(root);
        F.observers.push(sizes);
      };
      const sleep = () => {
        for (const o of F.observers) o.disconnect();
        F.observers = [];
        clearTimeout(F.timer);
        F.timer = 0;
        F.firstWait = 0;
      };
      const wake = () => {
        if (!F.query || F.observers.length || F.paused) return;
        observe();
        changed(true);
      };
      const watch = observe;
      const unwatch = sleep;

      F.pause = (paused) => {
        F.paused = paused;
        if (!F.query) return true;
        if (paused) sleep(); else wake();
        return true;
      };

      const selected = () => {
        for (const doc of F.docs) {
          const selection = doc.getSelection && doc.getSelection();
          if (selection && selection.rangeCount && !selection.isCollapsed) return { selection, range: selection.getRangeAt(0) };
        }
        return null;
      };

      F.mark = (query, names, colors, paused) => {
        F.names = names;
        F.colors = colors;
        F.paused = !!paused;
        if (F.paused) sleep();
        const same = query === F.query && F.index;
        F.query = query;
        const was = F.current !== null ? F.ranges[F.current] : null;
        if (!same) { unwatch(); F.index = null; }
        search();
        F.docs = F.index ? F.index.docs : [document];
        F.current = null;
        const found = selected();
        let i = found ? indexOf(found.range) : -1;
        // Nothing newly selected (the page finished loading): still the one you were on, if it's there.
        if (!found && i < 0) i = indexOf(was);
        if (i >= 0) {
          F.current = i;
          if (found) {
            // The selection's gray would cover the stronger color: a caret where it ended, selected again before the next find.
            found.selection.collapseToEnd();
            F.caret = { selection: found.selection, node: found.selection.focusNode, offset: found.selection.focusOffset };
          }
        }
        paint();
        if (F.query) watch();
        const now = snapshot();
        // What Zigzag hears now, so a look that finds the same says nothing.
        F.said = JSON.stringify(now);
        return now;
      };

      const select = (range) => {
        const selection = range.startContainer.ownerDocument.getSelection();
        selection.removeAllRanges();
        selection.addRange(range.cloneRange());
      };

      // The match you're on selected again, as WebKit left it: the find goes on from it either way, and says where it
      // landed counting from the top. Only if the caret is still where the last find left it: a click on the page
      // since starts the find from there.
      F.prepare = () => {
        const range = F.current !== null ? F.ranges[F.current] : null;
        const c = F.caret;
        if (!range || !c || !c.selection.isCollapsed || c.selection.focusNode !== c.node || c.selection.focusOffset !== c.offset) return false;
        select(range);
        return true;
      };

      // A tick clicked: the match before it selected, so the next find lands on it. The first: after the last, wrapping
      // around, or from the top if there are more than are marked.
      F.caretTo = (index) => {
        if (!F.ranges[index]) return false;
        if (index > 0) select(F.ranges[index - 1]);
        else if (F.count <= MAX) select(F.ranges[F.ranges.length - 1]);
        else for (const doc of F.docs) doc.getSelection().removeAllRanges();
        F.caret = null;
        return true;
      };

      F.clear = () => {
        unwatch();
        for (const doc of F.docs) unpaint(doc);
        for (const doc of [...F.layers.keys()]) unbox(doc);
        cancelAnimationFrame(F.placing);
        F.placing = 0;
        F.query = ''; F.index = null; F.ranges = []; F.count = 0; F.current = null; F.docs = []; F.caret = null; F.said = '';
        return true;
      };

      F.state = () => ({ query: F.query, count: F.count, current: F.current === null ? -1 : F.current, docs: F.docs.length,
        highlights: F.names ? Object.values(F.names).filter((n) => CSS.highlights.has(n)).length : 0, observers: F.observers.length,
        looks: F.looks, gap: F.gap, paused: F.paused, boxed: [...F.layers.values()].reduce((n, l) => n + l.ranges.length, 0) });

      globalThis.__zigzagFind = F;
    }
    """#
}

/// The ticks along the page's right edge, one for each match, the one you're on stronger. Drawn by Zigzag over the
/// web view, where the page can't reach it; a click on a tick goes to that match, and anywhere else falls through to
/// the page and its scroll bar.
final class FindMarksView: NSView {
    var snapshot = FindMarks.Snapshot.empty {
        didSet { if snapshot != oldValue { isHidden = snapshot.marks.isEmpty; needsDisplay = true } }
    }
    var onPick: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private var rects: [(index: Int, rect: CGRect)] {
        FindMarks.tickRects(snapshot, height: bounds.height, width: bounds.width, scale: window?.backingScaleFactor ?? 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rects = rects
        let current = snapshot.current
        let all = FindMarks.tickColor(current: false, dark: snapshot.dark)
        let strong = FindMarks.tickColor(current: true, dark: snapshot.dark)
        for (index, rect) in rects where rect.intersects(dirtyRect) {
            (index == current ? strong : all).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), FindMarks.tick(at: local.y, in: rects) != nil else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let index = FindMarks.tick(at: local.y, in: rects) { onPick?(index) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// Placed along the right edge of `webView`, the whole height, following it as it resizes.
    func attach(to webView: WKWebView) {
        if superview !== webView {
            removeFromSuperview()
            webView.addSubview(self)
        }
        frame = NSRect(x: webView.bounds.width - FindMarks.stripWidth, y: 0, width: FindMarks.stripWidth, height: webView.bounds.height)
        autoresizingMask = [.minXMargin, .height]
        needsDisplay = true
    }
}
