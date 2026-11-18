import WebKit

/// What the tools do inside a page: run in a content world of Zigzag's own, so the page's scripts can't see it, stand
/// in for it or change what it reports. It reads the DOM and acts on it; it never runs anything an app sends.
enum MCPPageScript {
    static let world = WKContentWorld.world(name: "app.zigzag.mcp")

    /// Records which fields were passwords while typed in, so PageState's rules keep them secret after a site's "Show
    /// password" makes them plain text.
    static let watch = WKUserScript(source: "(() => {\n\(PageState.secretWatch)\n})();", injectionTime: .atDocumentStart,
                                    forMainFrameOnly: true, in: world)

    /// Runs `op` with `args` in the page's main frame. The page's answer, or an error message.
    static func run(_ op: String, _ args: [String: Any] = [:], in webView: WKWebView) async -> Result<[String: Any], MCPArgumentError> {
        let sent: [String: Any]
        switch MCPRefs.inbound(args, for: webView) {
        case .failure(let error): return .failure(error)
        case .success(let args): sent = args
        }
        do {
            return answer(try await webView.callAsyncJavaScript(body, arguments: ["op": op, "args": sent], in: nil, contentWorld: world), from: webView)
        } catch {
            return failure(error)
        }
    }

    /// Starts `op` in the page and hands its answer to `then` when it comes. The request is on its way to the page
    /// when this returns, so what's sent to the web view after it (a key press) reaches the page after it too.
    static func start(_ op: String, _ args: [String: Any] = [:], in webView: WKWebView,
                      then: @escaping @MainActor (Result<[String: Any], MCPArgumentError>) -> Void) {
        let sent: [String: Any]
        switch MCPRefs.inbound(args, for: webView) {
        case .failure(let error): then(.failure(error)); return
        case .success(let args): sent = args
        }
        webView.callAsyncJavaScript(body, arguments: ["op": op, "args": sent], in: nil, in: world) { [weak webView] result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value):
                    guard let webView else { then(.failure(.init("The page gave no answer."))); return }
                    then(answer(value, from: webView))
                case .failure(let error): then(failure(error))
                }
            }
        }
    }

    /// The page's answer, its refs swapped for the ones apps are given.
    private static func answer(_ value: Any?, from webView: WKWebView) -> Result<[String: Any], MCPArgumentError> {
        guard let given = value as? [String: Any] else { return .failure(.init("The page gave no answer.")) }
        let object = MCPRefs.outbound(given, for: webView)
        if let error = object["error"] as? String { return .failure(.init(error)) }
        return .success(object)
    }

    private static func failure(_ error: Error) -> Result<[String: Any], MCPArgumentError> {
        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        return .failure(.init(message.map { "The page couldn't do it: \($0)" } ?? "The page couldn't do it."))
    }

    /// The function's body; `op` and `args` are its arguments.
    static let body = #"""
    \#(PageState.fieldRules)
    // State in this world, hidden from the page: fields the agent typed into, and each ref with what it stood for. Refs
    // and the page id are page-local: apps get Zigzag's own refs (MCPRefs).
    const zz = globalThis.__zigzagRefs || (globalThis.__zigzagRefs = { typed: new WeakMap(), byEl: new WeakMap(), byRef: new Map(), next: 0,
      page: globalThis.crypto && crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now().toString(36) });
    // A ref as the app has it, for what's said back.
    const shownRef = args.refShown || args.ref;
    const isSecret = (el) => {
      const type = (el.getAttribute && el.getAttribute('type') || '').toLowerCase();
      const ac = (el.getAttribute && el.getAttribute('autocomplete') || '').toLowerCase();
      return type === 'password' || (el.type || '').toLowerCase() === 'password' || ac.includes('password');
    };
    // A card number, by its digits' check sum, whatever field it's in.
    const isCardNumber = (value) => {
      const digits = String(value || '').replace(/[\s-]/g, '');
      if (!/^\d{13,19}$/.test(digits)) return false;
      let sum = 0;
      for (let i = 0; i < digits.length; i++) {
        let d = digits.charCodeAt(digits.length - 1 - i) - 48;
        if (i % 2) { d *= 2; if (d > 9) d -= 9; }
        sum += d;
      }
      return sum % 10 === 0;
    };
    // A value no app is given: a password, card details, a one-time code and the like (PageState.fieldRules), a hidden
    // input's value, or a card number in any field. Lists and rich-text fields are judged by what they declare and the
    // words they show.
    const sensitive = (el) => {
      if (isSecret(el)) return true;
      if (el instanceof HTMLInputElement && el.type === 'hidden') return true;
      const text = el instanceof HTMLTextAreaElement || (el instanceof HTMLInputElement && kinds.has(el.type));
      if (text && !keepable(el)) return true;
      if ((el instanceof HTMLSelectElement || editingHost(el)) && secretSaid(el)) return true;
      return isCardNumber(rawValue(el));
    };
    // A rich-text field: where its editing starts.
    const editingHost = (el) => !!el.isContentEditable && !isField(el) && !(el.parentElement && el.parentElement.isContentEditable);
    // A field's raw value, before any rule: a list's choice, a rich-text field's shown words, or its value.
    const rawValue = (el) => {
      if (el instanceof HTMLSelectElement) return el.selectedOptions.length ? el.selectedOptions[0].text : '';
      if (editingHost(el)) return textOf(el);
      return String(el.value ?? '');
    };
    // Saved-detail fields (name, email, phone, address): an app learns only that one is filled and its length, unless
    // it typed the value itself.
    const personal = /\b(name|honorific-prefix|given-name|additional-name|family-name|honorific-suffix|nickname|email|tel(-[a-z-]+)?|street-address|address-line[123]|address-level[1-4]|postal-code|country(-name)?|bday(-[a-z]+)?|organization(-title)?)\b/i;
    const autofilled = (el) => {
      for (const state of [':autofill', ':-webkit-autofill']) { try { if (el.matches(state)) return true; } catch (e) {} }
      return false;
    };
    const savedDetail = (el) => personal.test(el.getAttribute('autocomplete') || '') || autofilled(el);
    // Characters that change how text reads without showing (controls, direction marks, zero-width, soft hyphens,
    // Unicode tags): how hidden instructions ride along in page text.
    const unseen = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u00AD\u061C\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]|[\u{E0000}-\u{E007F}]/gu;
    const clip = (s, n) => {
      s = String(s ?? '').replace(unseen, '').replace(/\s+/g, ' ').trim();
      if (s.length <= n) return s;
      const chars = [...s];
      return chars.length > n ? chars.slice(0, n).join('') + '…' : s;
    };
    // A field's value as an app may have it: none for a password or secret, only the length for a saved detail the app
    // didn't type, otherwise the value.
    const valueOf = (el, max) => {
      if (isSecret(el)) return { password: true };
      const value = rawValue(el);
      // A value the app typed itself and the field still holds is no secret from it. Never a password, shown or not.
      const typedIt = value !== '' && zz.typed.get(el) === value && !(globalThis.__zigzagSecret && globalThis.__zigzagSecret.has(el));
      if (!typedIt && sensitive(el)) return { secret: true };
      if (value && !typedIt && savedDetail(el)) return { filled: [...value].length };
      return { value: clip(value, max) };
    };
    // A field: a box of its own, holding a value and none of the page's text.
    const isField = (el) => el.localName === 'input' || el.localName === 'textarea' || el.localName === 'select';
    // Whether a clip-path's inset() leaves nothing: opposite insets meet. An unreadable value (a calc()) counts as
    // leaving something.
    const insetLeavesNone = (path, box) => {
      const inset = /^inset\(([^)]*?)(?:\s+round\b[^)]*)?\)/.exec(path);
      if (!inset) return false;
      const parts = inset[1].trim().split(/\s+/);
      if (!parts[0] || parts.length > 4) return false;
      const [top, right = top, bottom = top, left = right] = parts;
      const px = (value, of) => value.endsWith('%') ? parseFloat(value) / 100 * of : parseFloat(value);
      const across = px(left, box.width) + px(right, box.width), down = px(top, box.height) + px(bottom, box.height);
      return (Number.isFinite(across) && across >= box.width) || (Number.isFinite(down) && down >= box.height);
    };
    // Clipped to nothing (the "visually hidden" pattern): a clip or clip-path that leaves nothing, or a box of a pixel
    // or less that hides its overflow.
    const clipsAway = (el, style, box) => {
      if ((style.position === 'absolute' || style.position === 'fixed') && style.clip && style.clip !== 'auto') {
        const n = style.clip.match(/-?[\d.]+/g);
        if (n && n.length === 4 && (n[2] - n[0]) * (n[1] - n[3]) <= 1) return true;
      }
      const path = style.clipPath || '';
      if (insetLeavesNone(path, box)) return true;
      if (/^circle\(\s*0(px|%)?[\s)]/.test(path)) return true;
      const ellipse = /^ellipse\(\s*([\d.]+)(?:px|%)?\s+([\d.]+)(?:px|%)?/.exec(path);
      if (ellipse && (Number(ellipse[1]) === 0 || Number(ellipse[2]) === 0)) return true;
      return box.width <= 1 && box.height <= 1 && style.overflow !== 'visible';
    };
    // A thin box: under 4 points (below readable text size, readableStyle) on a side it clips. Its contents never show,
    // though the box does (a 3-point seek bar). Not inline elements, which clip nothing, nor fields, which hold nothing
    // to clip.
    const thin = (el, style, box) => (box.width < 4 || box.height < 4) && !isField(el) && style.display !== 'inline'
      && ((box.width < 4 && style.overflowX !== 'visible') || (box.height < 4 && style.overflowY !== 'visible'));
    // Shrunk to nothing (the "scale(0)" pattern), judged by the transform's matrix so a move or rotation never counts.
    const flattened = (style) => {
      const scale = style.scale;
      if (scale && scale !== 'none' && scale.split(/\s+/).slice(0, 2).some((n) => Math.abs(parseFloat(n)) < 0.01)) return true;
      const transform = style.transform;
      if (!transform || transform === 'none') return false;
      const n = (transform.slice(transform.indexOf('(') + 1).match(/-?[\d.]+(?:e-?\d+)?/g) || []).map(Number);
      const [a, b, c, d] = transform.startsWith('matrix3d') ? [n[0], n[1], n[4], n[5]] : n;
      return Math.hypot(a, b) < 0.01 || Math.hypot(c, d) < 0.01;
    };
    // Outside the page's sideways scroll range (a right-to-left page scrolls the other way).
    const offSideways = (box) => {
      const page = document.scrollingElement || document.documentElement;
      // The root's direction, or the body's, sets the page's scroll direction.
      const rtl = [document.documentElement, document.body].some((el) => el && getComputedStyle(el).direction === 'rtl');
      const wide = Math.max(page.scrollWidth, innerWidth);
      const x = box.left + scrollX;
      return rtl ? x >= innerWidth || x + box.width <= innerWidth - wide : x + box.width <= 0 || x >= wide;
    };
    // Outside anything the page can be scrolled to.
    const offPage = (box) => {
      const page = document.scrollingElement || document.documentElement;
      const y = box.top + scrollY;
      return offSideways(box) || y + box.height <= 0 || y >= Math.max(page.scrollHeight, innerHeight);
    };
    // Parked out of sight (the "left: -9999px" pattern): positioned outside the scrollable area (for a fixed element,
    // the window). In-flow content is never parked: it can still be scrolled to.
    const parked = (style, box) => {
      if (style.position === 'fixed') return box.right <= 0 || box.bottom <= 0 || box.left >= innerWidth || box.top >= innerHeight;
      return style.position === 'absolute' && offPage(box);
    };
    // Every way a page hides something while leaving it in the page, in one place for all callers. The transform is
    // read only when the box is under 4 points.
    const tuckedAway = (el, style, box) => clipsAway(el, style, box) || ((box.width < 4 || box.height < 4) && flattened(style)) || parked(style, box);
    // So faint it's as good as see-through.
    const faint = (style) => { const opacity = style.opacity; return opacity !== '1' && parseFloat(opacity) < 0.1; };
    const host = (node) => node.parentElement || (node.parentNode && node.parentNode.host) || null;
    // Where a node is drawn: the slot a web component assigns it to, else its parent. Visibility is judged up that
    // chain.
    const drawnIn = (node) => node.assignedSlot || host(node);
    // A node's parent and containment in the composed tree, through shadow roots.
    const composedParent = (node) => node.parentNode instanceof ShadowRoot ? node.parentNode.host : node.parentNode;
    const composedContains = (outer, node) => {
      for (let at = node; at; at = composedParent(at)) if (at === outer) return true;
      return false;
    };
    // Whether a thin box above fails to clip an element placed apart (fixed, absolute): a WebKit hit test at a point of
    // its box beyond the strip finds it. A point outside the window can't be tested and counts as a no. Hit tests are
    // capped per call, as a collapsed box can hold hundreds of placed rows: past the cap the answer is no.
    let hitTests = 0;
    const paintedBeyond = (el, box, strip) => {
      const root = el.getRootNode(), from = root.elementsFromPoint ? root : document;
      // The hit is the element, or a descendant not itself placed apart (which gets its own answer).
      const itsOwn = (hit) => {
        for (let at = hit; at; at = composedParent(at)) {
          if (at === el) return true;
          if (at.nodeType === Node.ELEMENT_NODE && /^(fixed|absolute)$/.test(getComputedStyle(at).position)) return false;
        }
        return false;
      };
      const beyond = [
        [box.left, box.top, box.right, Math.min(box.bottom, strip.top)], [box.left, Math.max(box.top, strip.bottom), box.right, box.bottom],
        [box.left, box.top, Math.min(box.right, strip.left), box.bottom], [Math.max(box.left, strip.right), box.top, box.right, box.bottom],
      ];
      for (const [x0, y0, x1, y1] of beyond) {
        const left = Math.max(x0, 0), top = Math.max(y0, 0), right = Math.min(x1, innerWidth), bottom = Math.min(y1, innerHeight);
        if (right - left < 1 || bottom - top < 1) continue;
        if (++hitTests > 200) return false;
        if (from.elementsFromPoint((left + right) / 2, (top + bottom) / 2).some(itsOwn)) return true;
      }
      return false;
    };
    // What the person sees of an element, for every caller (a name, a click, a snapshot), from itself and its parent:
    //   GONE     nothing of it or in it: see-through, tucked away, or under something that is
    //   CLIPPED  under a thin box and outside its strip; something in it may still escape that box
    //   BOX      its box shows but not its direct text: a thin box, or something over a thin box's strip
    //   SHOWS    all of it
    // CLIPPED and BOX carry the strip in force (`strip`: its edges) for descendants. `opacity`: see-through counts as
    // gone (a click's reach ignores it). Callers check first whether it's drawn at all (checkVisibility).
    const GONE = 0, CLIPPED = 1, BOX = 2, SHOWS = 3;
    const ALL = { seen: SHOWS, strip: null }, NONE = { seen: GONE, strip: null };
    const under = (el, style, box, above, opacity) => {
      if (above.seen === GONE) return NONE;
      // No box of its own: as what holds it.
      if (style.display === 'contents') return above;
      if (tuckedAway(el, style, box) || (opacity && faint(style))) return NONE;
      let seen = SHOWS, strip = above.strip;
      if (strip) {
        // Placed apart and painted beyond the strip: the thin box doesn't clip it.
        if ((style.position === 'fixed' || style.position === 'absolute') && paintedBeyond(el, box, strip)) strip = null;
        // Over the strip its box shows (a fill in a thin track), except a field, whose clipped value would be read.
        else if (!isField(el) && Math.min(box.right, strip.right) - Math.max(box.left, strip.left) >= 1
          && Math.min(box.bottom, strip.bottom) - Math.max(box.top, strip.top) >= 1) seen = BOX;
        else seen = CLIPPED;
      }
      if (seen !== CLIPPED && thin(el, style, box)) {
        seen = BOX;
        strip = strip
          ? { left: Math.max(strip.left, box.left), top: Math.max(strip.top, box.top), right: Math.min(strip.right, box.right), bottom: Math.min(strip.bottom, box.bottom) }
          : { left: box.left, top: box.top, right: box.right, bottom: box.bottom };
      }
      return seen === SHOWS && !strip ? ALL : { seen, strip };
    };
    // Applies `under` from the top of the page down to the element, iteratively (a page can nest arbitrarily deep).
    // During a snapshot answers are cached so each element is examined once (only with `opacity`: a click's reach is
    // never cached). `style` and `box` are the element's own, when the caller has them.
    let known = null;
    const whatIs = (e, opacity, style, box) => {
      const keeps = known && opacity;
      const chain = [];
      let above = ALL;
      for (let at = e; at && at !== document.body && at !== document.documentElement; at = drawnIn(at)) {
        const kept = keeps ? known.get(at) : undefined;
        if (kept) { above = kept; break; }
        chain.push(at);
      }
      for (let i = chain.length - 1; i >= 0; i--) {
        const at = chain[i];
        above = above.seen === GONE ? NONE
          : under(at, at === e && style ? style : getComputedStyle(at), at === e && box ? box : at.getBoundingClientRect(), above, opacity);
        if (keeps) known.set(at, above);
      }
      return above;
    };
    const visibleBox = (el, opacity) => {
      if (!el || !el.isConnected) return GONE;
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: opacity, visibilityProperty: true })) return GONE;
      const box = el.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) return GONE;
      return whatIs(el, opacity, null, box).seen;
    };
    // Shows on the page, for the person to see: itself, whether or not what it holds does.
    const shown = (el) => visibleBox(el, true) >= BOX;
    // Shows, with the text right in it.
    const showsItsText = (el) => visibleBox(el, true) === SHOWS;
    // Reachable by the person's pointer, seen or not: a real click hits an invisible input laid over a picture of one.
    const hittable = (el) => visibleBox(el, false) >= BOX;
    const alpha = (color) => {
      const m = /rgba?\(([^)]*)\)/.exec(color || '');
      if (!m) return 1;
      const parts = m[1].split(/[\s,\/]+/).filter(Boolean);
      return parts.length > 3 ? parseFloat(parts[3]) : 1;
    };
    // Text the person can read: at least 4 points high and not see-through (unless drawn by its background, as gradient
    // headings are).
    const readableStyle = (style) => parseFloat(style.fontSize) >= 4
      && (alpha(style.webkitTextFillColor || style.color) > 0 || /text/.test(style.webkitBackgroundClip || style.backgroundClip || ''));
    // The ancestors that clip sideways and could hide text pushed by a text-indent. Null when the indent can't push
    // text out (it must be negative, or at least as wide as its block), which spares indented paragraphs. Cached per
    // call, as every text node asks.
    const pushing = new Map();
    const clipsWhenPushed = (owner, style) => {
      if (pushing.has(owner)) return pushing.get(owner);
      // What it's set in: the nearest above with a box of its own.
      let block = owner;
      while (block && host(block) && /^(inline|contents)$/.test(getComputedStyle(block).display)) block = host(block);
      const indent = style.textIndent, by = parseFloat(indent);
      let clips = null;
      if (by < 0 || by >= (indent.endsWith('%') ? 100 : block.clientWidth)) {
        clips = [];
        for (let at = owner; at; at = host(at)) if (getComputedStyle(at).overflowX !== 'visible') clips.push(at);
      }
      pushing.set(owner, clips);
      return clips;
    };
    // The sideways reach of a clipping element: its box, or its whole scroll width if it scrolls.
    const reaches = new Map();
    const reachOf = (el) => {
      let reach = reaches.get(el);
      if (!reach) {
        const box = el.getBoundingClientRect(), style = getComputedStyle(el);
        reach = !/auto|scroll/.test(style.overflowX) ? [box.left, box.right]
          : style.direction === 'rtl' ? [box.right - el.scrollLeft - el.scrollWidth, box.right - el.scrollLeft]
          : [box.left - el.scrollLeft, box.left - el.scrollLeft + el.scrollWidth];
        reaches.set(el, reach);
      }
      return reach;
    };
    // Whether text is drawn, where its element's style can't say: text pushed by a text-indent ("image replacement")
    // off the page or out of a clipping ancestor, and a custom element's text, which a closed shadow root may leave
    // out. Text directly inside a closed details never is, though WebKit still gives it a box.
    let ranger = null;
    const textHasBox = (node, owner, style) => {
      if (!node.data.trim()) return true;
      if (owner.localName === 'details' && !owner.open) return false;
      const clips = style.textIndent === '0px' ? null : clipsWhenPushed(owner, style);
      const drawnByThePage = owner.localName.includes('-') && !owner.shadowRoot;
      if (!clips && !drawnByThePage) return true;
      ranger = ranger || document.createRange();
      ranger.selectNodeContents(node);
      const boxes = [...ranger.getClientRects()].filter((box) => box.width > 0 && box.height > 0);
      if (!clips) return boxes.length > 0;
      // Pushed text shows only on the page and inside every ancestor that clips sideways. Past one that doesn't clip (a
      // number hung in the margin) it still shows.
      const within = clips.map(reachOf);
      return boxes.some((box) => !offSideways(box) && within.every(([left, right]) => box.right > left && box.left < right));
    };
    const fold = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();

    // Roles as screen readers have them: the page's if it's a known one, else the element's own.
    const ROLES = new Set(('alert alertdialog application article banner blockquote button caption cell checkbox code columnheader combobox '
      + 'complementary contentinfo definition deletion dialog directory document emphasis feed figure form generic grid gridcell group '
      + 'heading img insertion link list listbox listitem log main mark marquee math menu menubar menuitem menuitemcheckbox menuitemradio '
      + 'meter navigation none note option paragraph presentation progressbar radio radiogroup region row rowgroup rowheader scrollbar '
      + 'search searchbox separator slider spinbutton status strong subscript superscript switch tab table tablist tabpanel term textbox '
      + 'time timer toolbar tooltip tree treegrid treeitem').split(' '));
    const INTERACTIVE = new Set(['button', 'checkbox', 'combobox', 'link', 'listbox', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
      'option', 'radio', 'searchbox', 'slider', 'spinbutton', 'switch', 'tab', 'textbox', 'treeitem']);
    const NAMED_BY_CONTENT = new Set(['button', 'cell', 'checkbox', 'columnheader', 'gridcell', 'heading', 'link', 'menuitem',
      'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'row', 'rowheader', 'switch', 'tab', 'tooltip', 'treeitem']);
    const SKIPPED = new Set(['script', 'style', 'template', 'noscript', 'head', 'meta', 'link']);
    const INLINE = new Set(['a', 'abbr', 'b', 'bdi', 'bdo', 'cite', 'code', 'data', 'dfn', 'em', 'font', 'i', 'kbd', 'label', 'mark', 'q', 's',
      'samp', 'small', 'span', 'strong', 'sub', 'sup', 'time', 'u', 'var']);
    const focusable = (el) => el.tabIndex >= 0 && !(el.matches && el.matches(':disabled'));
    const implicitRole = (el) => {
      const tag = el.localName;
      // A rich-text editing host is a field, whatever its element (a list item, a heading).
      if (editingHost(el)) return 'textbox';
      if (/^h[1-6]$/.test(tag)) return 'heading';
      switch (tag) {
      case 'a': case 'area': return el.hasAttribute('href') ? 'link' : null;
      case 'button': return 'button';
      case 'summary': return el.parentElement && el.parentElement.localName === 'details' ? 'button' : null;
      case 'input': {
        const type = (el.type || 'text').toLowerCase();
        if (['button', 'submit', 'reset', 'image', 'file'].includes(type)) return 'button';
        if (type === 'checkbox' || type === 'radio') return type;
        if (type === 'range') return 'slider';
        if (type === 'number') return 'spinbutton';
        if (type === 'hidden') return null;
        if (el.hasAttribute('list')) return 'combobox';
        return type === 'search' ? 'searchbox' : 'textbox';
      }
      case 'textarea': return 'textbox';
      case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
      case 'option': return 'option';
      case 'img': return el.getAttribute('alt') === '' ? null : 'img';
      case 'nav': return 'navigation';
      case 'main': return 'main';
      case 'aside': return 'complementary';
      case 'header': return el.closest('article, aside, main, nav, section') ? null : 'banner';
      case 'footer': return el.closest('article, aside, main, nav, section') ? null : 'contentinfo';
      case 'form': return 'form';
      case 'section': return 'region';
      case 'search': return 'search';
      case 'dialog': return 'dialog';
      case 'ul': case 'ol': case 'menu': return 'list';
      case 'li': return 'listitem';
      case 'table': return 'table';
      case 'tr': return 'row';
      case 'td': return 'cell';
      case 'th': return 'columnheader';
      case 'fieldset': case 'details': return 'group';
      case 'progress': return 'progressbar';
      case 'meter': return 'meter';
      }
      return null;
    };
    const roleOf = (el) => {
      const given = (el.getAttribute('role') || '').trim().toLowerCase().split(/\s+/).find((r) => ROLES.has(r));
      if (given && !((given === 'presentation' || given === 'none') && focusable(el))) return given === 'none' ? 'presentation' : given;
      return implicitRole(el);
    };
    const childrenOf = (el) => {
      if (el.shadowRoot) return el.shadowRoot.childNodes;
      if (el.localName === 'slot') { const given = el.assignedNodes({ flatten: true }); return given.length ? given : el.childNodes; }
      return el.childNodes;
    };
    // An element's text for a name: only what the person can read, unless `hidden` (what a label points at). Fields
    // give their value, images their alt, and `skip` (the field a label is for) is left out. `textOf.cut`: the last
    // text was longer than a name holds.
    const textOf = (el, { hidden = false, skip = null } = {}) => {
      let out = '', depth = 0, more = false;
      const walk = (node) => {
        if (out.length > 300) { more = true; return; }
        if (node.nodeType === Node.TEXT_NODE) {
          const owner = host(node);
          if (hidden) { out += node.data; return; }
          if (!owner || !showsItsText(owner)) return;
          // Given to a slot, it's drawn there: in a part of the component that shows.
          if (node.assignedSlot && whatIs(node.assignedSlot, true).seen !== SHOWS) return;
          const style = getComputedStyle(owner);
          if (readableStyle(style) && textHasBox(node, owner, style)) out += node.data;
          return;
        }
        if (node.nodeType !== Node.ELEMENT_NODE || node === skip || SKIPPED.has(node.localName)) return;
        if (!hidden && node.getAttribute('aria-hidden') === 'true') return;
        const tag = node.localName;
        if (tag === 'br') { out += ' '; return; }
        if (tag === 'img' || (tag === 'input' && node.type === 'image')) {
          if (hidden || shown(node)) out += ' ' + (node.getAttribute('alt') || '') + ' ';
          return;
        }
        if (node !== el && (tag === 'input' || tag === 'select' || tag === 'textarea')) {
          // Only a value that shows (a field's text, a slider's value, a list's choice). A checkbox's or radio's value
          // is never seen.
          const shows = tag !== 'input' || kinds.has((node.type || 'text').toLowerCase()) || node.type === 'range';
          const value = shows ? valueOf(node, 100).value : '';
          if (value) out += ' ' + value + ' ';
          return;
        }
        const block = !INLINE.has(tag);
        if (block) out += ' ';
        // A name is never looked for deeper than this: a page can nest without end.
        if (depth >= 200) { more = true; return; }
        depth += 1;
        for (const child of childrenOf(node)) walk(child);
        depth -= 1;
        if (block) out += ' ';
      };
      walk(el);
      const text = clip(out, 100);
      textOf.cut = more || text.endsWith('…');
      return text;
    };
    // What a screen reader would call a field's label, a button's value, an image's alt and the like.
    const nativeName = (el) => {
      const tag = el.localName;
      if (el.labels && el.labels.length) return [...el.labels].map((label) => textOf(label, { hidden: true, skip: el })).join(' ');
      if (tag === 'input' && ['button', 'submit', 'reset'].includes(el.type)) return (showsValue(el) && el.value) || (el.type === 'submit' ? 'Submit' : el.type === 'reset' ? 'Reset' : '');
      if (tag === 'input' && el.type === 'image') return el.getAttribute('alt') || el.getAttribute('title') || 'Submit';
      if (tag === 'img' || tag === 'area') return el.getAttribute('alt') || '';
      const caption = { fieldset: 'legend', figure: 'figcaption', table: 'caption' }[tag];
      if (caption) { const part = el.querySelector(':scope > ' + caption); return part ? textOf(part) : ''; }
      return '';
    };
    // An element's name in screen-reader order (aria-labelledby, aria-label, label, text, title), with two departures
    // that keep unseen words from an agent: text only counts if it shows, and shown text wins over a label that
    // differs.
    const names = new Map();
    const nameOf = (el) => {
      if (names.has(el)) return names.get(el);
      const role = roleOf(el);
      const root = el.getRootNode();
      const ids = (el.getAttribute('aria-labelledby') || '').trim();
      const by = ids ? ids.split(/\s+/).map((id) => root.getElementById ? root.getElementById(id) : document.getElementById(id))
        .filter((target) => target && target !== el).map((target) => textOf(target, { hidden: true })).join(' ') : '';
      const authored = clip(by || el.getAttribute('aria-label') || '', 100);
      const native = clip(nativeName(el), 100);
      const content = NAMED_BY_CONTENT.has(role) ? textOf(el) : '';
      const contentCut = !!content && textOf.cut;
      const seen = content || (el.labels && [...el.labels].some(shown) ? native : '');
      let name = authored || native || content;
      // A wordless icon is named by its SVG's title, as by an aria-label.
      if (!name && (INTERACTIVE.has(role) || role === 'img' || el.localName === 'svg' || el.hasAttribute('tabindex'))) {
        const title = el.localName === 'svg' ? el.querySelector(':scope > title') : el.querySelector('svg > title');
        if (title) name = clip(title.textContent, 100);
      }
      if (!name && (INTERACTIVE.has(role) || el.hasAttribute('tabindex'))) name = clip(el.getAttribute('title') || el.getAttribute('placeholder') || '', 100);
      // Shown words win over a label that says something else. A lone sign (×, +, ›) is an icon, named by its label.
      const words = /[\p{L}\p{N}]/u.test(seen);
      const named = authored && words && !fold(authored).includes(fold(seen)) ? { name: seen, labelDiffers: true } : { name };
      // Named by its own text, and whether the name is partial: a snapshot then lists the rest under it.
      if (named.name && named.name === content) { named.fromContent = true; named.partial = contentCut; }
      names.set(el, named);
      return named;
    };
    const cssEscape = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c);
    const selectorFor = (el) => {
      if (el.id && document.querySelectorAll('#' + cssEscape(el.id)).length === 1) return '#' + cssEscape(el.id);
      const name = el.getAttribute('name');
      const tag = el.tagName.toLowerCase();
      if (name) {
        const sel = tag + '[name="' + name.replace(/["\\]/g, '\\$&') + '"]';
        if (document.querySelectorAll(sel).length === 1) return sel;
      }
      const parts = [];
      let node = el;
      while (node && node.nodeType === 1 && node !== document.documentElement && parts.length < 8) {
        let part = node.tagName.toLowerCase();
        if (node.id && document.querySelectorAll('#' + cssEscape(node.id)).length === 1) { parts.unshift('#' + cssEscape(node.id)); break; }
        const parent = node.parentElement;
        if (parent) {
          const same = [...parent.children].filter((c) => c.tagName === node.tagName);
          if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
        }
        parts.unshift(part);
        node = parent;
      }
      return parts.join(' > ');
    };
    // A field's value is what's typed or filled in, so never a name for it; only a button's value is its caption.
    const showsValue = (el) => el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes((el.type || '').toLowerCase()) && !sensitive(el);
    // The element the keys go to: through open shadow roots and frames of this page's own origin, down to the one
    // with the focus. A frame of another origin stays the frame, as nothing in it can be seen from here.
    const deepActive = () => {
      let active = document.activeElement;
      for (let depth = 0; active && depth < 32; depth++) {
        if (active.shadowRoot && active.shadowRoot.activeElement) { active = active.shadowRoot.activeElement; continue; }
        if (active.tagName === 'IFRAME' || active.tagName === 'FRAME') {
          let inner = null;
          try { inner = active.contentDocument; } catch (e) { inner = null; }
          const next = inner && inner.activeElement;
          if (next && next !== inner.body && next !== inner.documentElement) { active = next; continue; }
        }
        break;
      }
      return active;
    };
    const find = (selector) => {
      try { return document.querySelector(selector); } catch (e) { throw new Error('Invalid CSS selector: ' + selector); }
    };
    // What a ref stands for. Any change gives a new ref, so an old ref can't act on something else.
    const printOf = (el) => [roleOf(el) || el.localName, nameOf(el).name, el.getAttribute('href') || '', el.type || ''].join('\u0001');
    const said = (el) => {
      const name = nameOf(el).name;
      return (roleOf(el) || el.localName) + (name ? ' ' + JSON.stringify(name) : '');
    };
    // Periodically drops refs to elements that left the page, here and (through refsGone) in Zigzag (MCPRefs), so a
    // long-lived page doesn't pile them up.
    const letGo = () => {
      for (const [ref, entry] of zz.byRef) {
        const el = entry.el.deref();
        if (el && el.isConnected) continue;
        zz.byRef.delete(ref);
        (zz.gone || (zz.gone = [])).push(ref);
      }
    };
    const refFor = (el) => {
      const print = printOf(el);
      const known = zz.byEl.get(el);
      if (known && zz.byRef.get(known)?.print === print) return known;
      // The element changed: its old ref is dropped here and, with the answer, on Zigzag's side.
      if (known) { zz.byRef.delete(known); (zz.gone || (zz.gone = [])).push(known); }
      const ref = 'e' + (++zz.next);
      if (zz.next % 500 === 0) letGo();
      zz.byEl.set(el, ref);
      zz.byRef.set(ref, { el: new WeakRef(el), print, was: said(el) });
      return ref;
    };
    // An element as tools report it: its ref, screen-reader role and name, and a selector.
    const describe = (el) => ({ ref: refFor(el), role: roleOf(el) || el.localName, name: nameOf(el).name, tag: el.localName, selector: selectorFor(el) });
    // The element a tool names: by ref (only while unchanged), CSS selector, or shown text (something clickable). Never
    // guessed from a ref's role or name. { el } or { error }.
    const clickable = 'a, button, input[type=button], input[type=submit], input[type=reset], [role=button], [role=link], [role=tab], '
      + '[role=menuitem], [role=option], [role=checkbox], summary, label, [onclick]';
    const resolve = (args) => {
      if (args.ref) {
        const entry = args.refPage === zz.page ? zz.byRef.get(args.ref) : null;
        const el = entry && entry.el.deref();
        if (!el || !el.isConnected) return { error: shownRef + ' isn’t on this page now: the page changed or loaded again since your snapshot. Take a new snapshot.' };
        if (printOf(el) !== entry.print) return { error: shownRef + ' changed since your snapshot (it was ' + entry.was + '). Take a new snapshot.' };
        return { el };
      }
      if (args.selector) {
        const el = find(args.selector);
        return el ? { el } : { error: 'Nothing on the page matches ' + args.selector + '.' };
      }
      if (args.text) {
        const want = fold(args.text);
        const candidates = [...document.querySelectorAll(clickable)].filter(shown);
        const text = (c) => fold(c.innerText || (showsValue(c) ? c.value : '') || c.getAttribute('aria-label') || c.getAttribute('title') || '');
        const el = candidates.find((c) => text(c) === want) || candidates.find((c) => text(c).includes(want));
        return el ? { el } : { error: 'Nothing clickable on the page says “' + args.text + '”.' };
      }
      return { el: null };
    };
    // The top open dialog, which has the person's attention: the one holding the focus (showModal() puts it there and
    // makes the rest inert), through shadow roots, else the last one open.
    const topModal = () => {
      const isModal = (el) => { try { return el.localName === 'dialog' && el.matches(':modal'); } catch (e) { return false; } };
      for (let at = deepActive(); at; at = composedParent(at)) if (at.nodeType === Node.ELEMENT_NODE && isModal(at)) return at;
      const open = document.querySelectorAll('dialog:modal');
      return open.length ? open[open.length - 1] : null;
    };
    // Set aside: inside something inert, or outside the top dialog (which makes the rest inert), through shadow roots.
    const setAside = (el) => {
      const modal = topModal();
      let inModal = !modal;
      for (let at = el; at; at = composedParent(at)) {
        if (at.nodeType === Node.ELEMENT_NODE && at.hasAttribute('inert')) return true;
        if (at === modal) inModal = true;
      }
      return !inModal;
    };
    // Out of the person's sight: it doesn't show, or an ancestor (through shadow roots) is hidden from screen readers
    // or inert.
    const outOfSight = (el) => {
      if (!shown(el)) return true;
      for (let at = el; at; at = composedParent(at)) {
        if (at.nodeType === Node.ELEMENT_NODE && (at.getAttribute('aria-hidden') === 'true' || at.hasAttribute('inert'))) return true;
      }
      return false;
    };
    // What keeps the person from using an element: it's disabled (itself, by an ancestor, or by aria-disabled) or set
    // aside. { error } or null.
    const blocked = (el, who) => {
      if (el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true') return { error: 'That element is disabled.' };
      if (setAside(el)) return { error: who + ' can’t be used now: something else on the page (a dialog) has the person’s attention.' };
      return null;
    };
    // Where an element's keys go: in rich text, the editing host (an editor's paragraph can't take the focus), else the
    // element.
    const keysGoTo = (el) => {
      let at = el;
      if (el.isContentEditable && !isField(el)) while (!editingHost(at) && at.parentElement) at = at.parentElement;
      return at;
    };
    // Focuses the element as a click or Tab would, and reports whether it took: WebKit focuses nothing hidden, disabled
    // or inert. It needn't show (a code editor's input doesn't). Called last, once nothing else can refuse, as it
    // scrolls and moves the focus. { error } or null.
    const focused = (el, who) => {
      const target = keysGoTo(el);
      const holds = () => { const now = deepActive(); return now === target || target.contains(document.activeElement) || !!(target.shadowRoot && target.shadowRoot.contains(now)); };
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      // Already in it (the caret in an editor): left where it is.
      if (!holds() && typeof target.focus === 'function') target.focus({ preventScroll: true });
      return holds() ? null : { error: who + ' can’t take the keyboard focus, so keys would go somewhere else.' };
    };
    // Whether a click would reach the element as the person's would: nothing blocks it, it shows, and nothing covers it
    // once scrolled into view. A checkbox or radio the page hides and draws itself is clicked through its label. {
    // target, x, y } or { error }.
    const reachable = (el, who) => {
      const stop = blocked(el, who);
      if (stop) return stop;
      let target = el;
      if (!hittable(el)) {
        const label = el.labels && [...el.labels].find(shown);
        if (!label) return { error: who + ' is on the page but doesn’t show, so it can’t be clicked.' };
        target = label;
      }
      // Instant, whatever the page's scroll-behavior: the click is checked and lands where the element is now.
      target.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      // Clicks the first of its boxes in the window with nothing over its middle (a link over two lines has two, and
      // the middle of both may be on neither).
      const inView = [...target.getClientRects()]
        .map((box) => ({ left: Math.max(box.left, 0), right: Math.min(box.right, innerWidth), top: Math.max(box.top, 0), bottom: Math.min(box.bottom, innerHeight) }))
        .filter((box) => box.right > box.left && box.bottom > box.top);
      if (!inView.length) return { error: who + ' can’t be scrolled into view.' };
      const root = target.getRootNode();
      let over = null;
      for (const box of inView) {
        const x = (box.left + box.right) / 2, y = (box.top + box.bottom) / 2;
        const hit = (root.elementFromPoint ? root : document).elementFromPoint(x, y);
        if (!hit || composedContains(target, hit) || composedContains(hit, target)
          || (el.labels && [...el.labels].some((label) => composedContains(label, hit)))) return { target, x, y };
        over = over || hit;
      }
      return { error: 'Something covers ' + who + ': ' + said(over) + ' is on top of it. Close it or scroll it out of the way first.' };
    };

    const answer = await (async () => {
    switch (op) {
    case 'read': {
      const root = document.body || document.documentElement;
      const all = root ? root.innerText || '' : '';
      const max = args.maxChars;
      const fields = [];
      for (const el of document.querySelectorAll('input, textarea, select')) {
        if (fields.length >= 100) break;
        const type = (el.type || el.tagName).toLowerCase();
        if (type === 'hidden' || !shown(el)) continue;
        const field = { ref: refFor(el), selector: selectorFor(el), tag: el.tagName.toLowerCase(), type, label: nameOf(el).name, name: el.getAttribute('name') || '' };
        if (type === 'checkbox' || type === 'radio') {
          field.checked = el.checked;
        } else {
          const value = valueOf(el, el.tagName === 'SELECT' ? 200 : 500);
          if (value.password) field.password = true;
          else if (value.secret) field.secret = true;
          else if (value.filled != null) field.filled = value.filled;
          else {
            field.value = value.value;
            if (el.tagName === 'SELECT') field.options = [...el.options].slice(0, 50).map((o) => clip(o.text, 80));
          }
        }
        fields.push(field);
      }
      return { title: document.title, url: location.href, text: all.length > max ? all.slice(0, max) : all, length: all.length,
               truncated: all.length > max, fields };
    }
    case 'links': {
      const seen = new Set();
      const links = [];
      let total = 0;
      for (const a of document.querySelectorAll('a[href]')) {
        const href = a.href;
        if (!/^https?:/i.test(href)) continue;
        const text = clip(a.innerText || a.getAttribute('aria-label') || a.getAttribute('title') || '', 200);
        const key = href + '\n' + text;
        if (seen.has(key)) continue;
        seen.add(key);
        total += 1;
        if (links.length < args.max) links.push({ text, url: href });
      }
      return { links, total, truncated: total > links.length };
    }
    case 'click': {
      const found = resolve(args);
      if (found.error) return found;
      const el = found.el;
      const reach = reachable(el, shownRef || 'That element');
      if (reach.error) return reach;
      const target = reach.target;
      const at = { bubbles: true, cancelable: true, composed: true, view: window, clientX: reach.x, clientY: reach.y, button: 0 };
      for (const kind of ['pointerdown', 'mousedown']) target.dispatchEvent(new (kind.startsWith('pointer') && window.PointerEvent ? PointerEvent : MouseEvent)(kind, at));
      if (typeof target.focus === 'function') target.focus({ preventScroll: true });
      for (const kind of ['pointerup', 'mouseup']) target.dispatchEvent(new (kind.startsWith('pointer') && window.PointerEvent ? PointerEvent : MouseEvent)(kind, at));
      // An SVG has no click() of its own.
      if (typeof target.click === 'function') target.click(); else target.dispatchEvent(new MouseEvent('click', at));
      names.clear();
      return { clicked: describe(el) };
    }
    case 'type': {
      const found = resolve(args);
      if (found.error) return found;
      const el = found.el;
      if (isSecret(el)) return { error: 'password' };
      if (!isField(el) && !el.isContentEditable) return { error: 'That element isn’t a field: ' + el.tagName.toLowerCase() + '.' };
      // Every refusal comes before the focus moves, so a refused call leaves the page unchanged.
      const who = shownRef || 'That field';
      // A piece of a rich-text field (an editor's paragraph) isn't a field: typing goes to the whole field, and
      // clearing would empty it.
      if (!isField(el) && !editingHost(el)) {
        return { error: (shownRef || 'That element') + ' is part of a rich-text field, not a field. Type in the field itself (it has a ref of its own in the snapshot), or click where the text should go and use press_key.' };
      }
      const stop = blocked(el, who);
      if (stop) return stop;
      if (el.tagName !== 'SELECT' && isField(el) && el.readOnly) return { error: 'That field can’t be typed in.' };
      let option = null;
      if (el.tagName === 'SELECT') {
        const want = args.text.trim().toLowerCase();
        const options = [...el.options];
        option = options.find((o) => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want)
          || options.find((o) => o.text.toLowerCase().includes(want));
        if (!option) return { error: 'The list has no option “' + args.text + '”. It has: ' + options.slice(0, 30).map((o) => o.text.trim()).join(', ') };
      }
      const unfocused = focused(el, who);
      if (unfocused) return unfocused;
      if (option) {
        el.value = option.value;
        zz.typed.set(el, rawValue(el));
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        names.clear();
        return { typed: describe(el), value: option.text.trim() };
      }
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
        const value = args.clear ? args.text : el.value + args.text;
        // The whole value is the app's own when it replaced what was there, or added to its own text or to nothing.
        // Added to anything else, it no longer is.
        const allItsOwn = args.clear || el.value === '' || zz.typed.get(el) === el.value;
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        if (allItsOwn) zz.typed.set(el, value); else zz.typed.delete(el);
        el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: args.text }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      } else {
        if (args.clear) { document.execCommand('selectAll', false, null); document.execCommand('delete', false, null); }
        document.execCommand('insertText', false, args.text);
        zz.typed.delete(el);
      }
      let submitted = false;
      if (args.submit) {
        const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
        const goOn = el.dispatchEvent(new KeyboardEvent('keydown', key));
        el.dispatchEvent(new KeyboardEvent('keyup', key));
        if (goOn && el.form) {
          if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
          submitted = true;
        }
      }
      names.clear();
      return { typed: describe(el), submitted };
    }
    case 'scroll': {
      let target = null;
      if (args.ref || args.selector) {
        const found = resolve(args);
        if (found.error) return found;
        target = found.el;
        target.scrollBy({ top: args.dy, behavior: 'instant' });
        return { scrollTop: target.scrollTop, scrollHeight: target.scrollHeight, height: target.clientHeight };
      }
      window.scrollBy({ top: args.dy, behavior: 'instant' });
      const page = document.scrollingElement || document.documentElement;
      return { scrollTop: window.scrollY, scrollHeight: page.scrollHeight, height: window.innerHeight };
    }
    case 'waitFor': {
      // Checked when the page changes (a MutationObserver), and every quarter second besides, for what changes
      // without touching the DOM (a style sheet, an animation). Zigzag ends it on time; the page's own timer only
      // tidies up if that never comes.
      const waits = globalThis.__zigzagWaits || (globalThis.__zigzagWaits = new Map());
      const norm = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
      const want = norm(args.value);
      const visible = () => {
        try { return [...document.querySelectorAll(args.value)].find(shown) || null; } catch (e) { throw new Error('Invalid CSS selector: ' + args.value); }
      };
      const pageText = () => norm((document.body || document.documentElement || {}).innerText);
      const check = () => {
        switch (args.condition) {
        case 'text': return pageText().includes(want) ? {} : null;
        case 'text_gone': return pageText().includes(want) ? null : {};
        case 'selector': { const el = visible(); return el ? { element: describe(el) } : null; }
        case 'selector_gone': return visible() ? null : {};
        case 'load': return document.readyState === 'complete' ? {} : null;
        default: throw new Error('Unknown condition.');
        }
      };
      if (args.condition === 'selector' || args.condition === 'selector_gone') visible();
      return await new Promise((resolve) => {
        let done = false, last = 0, later = null, poll = null, cleanup = null;
        const observer = new MutationObserver(() => soon());
        const finish = (value) => {
          if (done) return;
          done = true;
          observer.disconnect();
          clearInterval(poll);
          clearTimeout(cleanup);
          clearTimeout(later);
          removeEventListener('pagehide', gone, true);
          document.removeEventListener('readystatechange', run);
          waits.delete(args.waitID);
          resolve(value);
        };
        const run = () => {
          later = null;
          if (done) return;
          last = performance.now();
          let hit = null;
          try { hit = check(); } catch (e) { finish({ error: String(e.message || e) }); return; }
          if (hit) finish(Object.assign({ matched: args.condition }, hit));
        };
        // At most every 50 ms, however fast the page changes.
        const soon = () => {
          if (done || later) return;
          const wait = 50 - (performance.now() - last);
          if (wait <= 0) run(); else later = setTimeout(run, wait);
        };
        const gone = () => finish({ navigated: true });
        waits.set(args.waitID, () => finish({ cancelled: true }));
        addEventListener('pagehide', gone, true);
        document.addEventListener('readystatechange', run);
        observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
        poll = setInterval(run, 250);
        cleanup = setTimeout(() => finish({ timedOut: true }), args.timeoutMs + 2000);
        run();
      });
    }
    case 'cancelWait': {
      const stop = globalThis.__zigzagWaits && globalThis.__zigzagWaits.get(args.waitID);
      if (stop) stop();
      return { cancelled: !!stop };
    }
    case 'keyTarget': {
      // Where press_key's key will go: the element a selector finds, focused first, or the one with the focus.
      if (args.ref || args.selector) {
        const found = resolve(args);
        if (found.error) return found;
        const who = shownRef || 'That element';
        const stop = blocked(found.el, who) || focused(found.el, who);
        names.clear();
        if (stop) return stop;
      }
      const active = deepActive();
      const page = !active || active === document.body || active === document.documentElement;
      return { focused: page ? null : describe(active), secret: !page && isSecret(active),
               inFrame: !page && (active.tagName === 'IFRAME' || active.tagName === 'FRAME') };
    }
    case 'awaitKey': {
      // Answers once the page has had the key up (so what the key down did is done), or after a moment.
      return await new Promise((resolve) => {
        let timer = null;
        const finish = () => {
          removeEventListener('keyup', up, true);
          clearTimeout(timer);
          const active = deepActive();
          const page = !active || active === document.body || active === document.documentElement;
          resolve({ focused: page ? null : describe(active) });
        };
        const up = (e) => { if (e.isTrusted) finish(); };
        addEventListener('keyup', up, true);
        timer = setTimeout(finish, 1000);
      });
    }
    case 'snapshot': {
      // The page as a screen reader has it: landmarks, headings, text, and each usable element with a ref. Only what
      // shows. MCPSnapshot writes it out. A budget keeps a huge page from blocking the page's thread.
      const started = performance.now();
      // The dialog on top, if it's one the person sees; otherwise the whole page.
      const modal = args.ref ? null : [topModal()].find((open) => open && !outOfSight(open)) || null;
      let root = null;
      if (args.ref) {
        const found = resolve(args);
        if (found.error) return found;
        if (outOfSight(found.el)) return { error: shownRef + ' doesn’t show on the page now, so there’s nothing of it to read.' };
        root = found.el;
      } else if (modal) root = modal;
      known = new Map();
      // [new]: not listed in this page's last snapshot.
      const before = zz.listed, listed = new Set();
      let visited = 0, refs = 0, cut = false;
      const styles = new Map();
      const styleOf = (el) => { let style = styles.get(el); if (!style) { style = getComputedStyle(el); styles.set(el, style); } return style; };
      const STRUCTURE = new Set(['alert', 'alertdialog', 'article', 'banner', 'cell', 'columnheader', 'complementary', 'contentinfo', 'dialog',
        'grid', 'heading', 'list', 'listitem', 'main', 'menu', 'menubar', 'navigation', 'radiogroup', 'row', 'rowheader', 'search', 'status',
        'table', 'tablist', 'tabpanel', 'toolbar', 'tree']);
      const NAMED_ONLY = new Set(['form', 'region', 'group']);
      const VALUED = new Set(['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider']);
      // Listed even when empty, as their name says what they hold. Other landmarks and lists need content.
      const ON_THEIR_OWN = new Set(['heading', 'dialog', 'alertdialog', 'alert', 'status']);
      const mixedScripts = (s) => /(?=\S*\p{Script=Latin})(?=\S*\p{Script=Cyrillic}|\S*\p{Script=Greek})\S+/u.test(s || '');
      // Left out with all it holds, before `whatIs`: what a snapshot never reads, and what isn't drawn (content a
      // closed shadow root leaves out has a normal style and no box).
      const leftOut = (el, style, box) => {
        if (SKIPPED.has(el.localName) || el.getAttribute('aria-hidden') === 'true' || el.hasAttribute('inert')) return true;
        if (style.display === 'none' || style.contentVisibility === 'hidden') return true;
        if (style.display === 'contents') return false;
        return box.width === 0 && box.height === 0 && !!el.checkVisibility && !el.checkVisibility();
      };
      const statesOf = (el, role) => {
        const states = {};
        const aria = (name) => el.getAttribute('aria-' + name);
        if (['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(role)) {
          const native = el.localName === 'input' && (el.type === 'checkbox' || el.type === 'radio');
          const checked = native ? (el.indeterminate ? 'mixed' : el.checked) : (aria('checked') === 'mixed' ? 'mixed' : aria('checked') === 'true');
          if (checked) states.checked = checked;
        }
        if (el.matches(':disabled') || aria('disabled') === 'true') states.disabled = true;
        if (aria('expanded') === 'true' || (el.localName === 'summary' && el.parentElement && el.parentElement.open)) states.expanded = true;
        if (aria('selected') === 'true' || (el.localName === 'option' && el.selected)) states.selected = true;
        if (aria('pressed') === 'true') states.pressed = true; else if (aria('pressed') === 'mixed') states.pressed = 'mixed';
        if (role === 'heading') { const tag = /^h([1-6])$/.exec(el.localName); states.level = Number(aria('level')) || (tag ? Number(tag[1]) : 2); }
        if (el.required || aria('required') === 'true') states.required = true;
        if (el.getRootNode().activeElement === el) states.active = true;
        return states;
      };
      const linkURL = (el) => {
        const href = el.href ? String(el.href) : '';
        return /^(https?|mailto|tel):/i.test(href) ? href.slice(0, 2000) : null;
      };
      // A run of text is a line: at most this long, and one cut short says so.
      const RUN = 1000;
      const flush = (out, ctx) => {
        const text = clip(ctx.run, RUN);
        ctx.run = '';
        if (!text || ctx.mute) return;
        const item = { role: 'text', text }, flags = [];
        if (text.length > RUN && [...text].length > RUN) flags.push('shortened');
        if (mixedScripts(text)) flags.push('mixedScripts');
        if (flags.length) item.flags = flags;
        out.push(item);
      };
      // What's in `parent`, into `out`: text gathered across inline elements, flushed at each block and node.
      const walk = (parent, out, ctx) => {
        // A closed details shows its summary and only what else the page still draws.
        const closed = parent.localName === 'details' && !parent.open;
        for (const child of childrenOf(parent)) {
          if (cut) return;
          if (closed && child.nodeType === Node.ELEMENT_NODE && child.checkVisibility && !child.checkVisibility()) continue;
          if (child.nodeType === Node.TEXT_NODE) {
            const owner = host(child);
            if (owner) {
              const style = styleOf(owner);
              // Direct text shows only when its whole element does (not in a thin box), and the slot it's drawn in
              // (`parent`), if any, does too.
              if (style.visibility === 'visible' && readableStyle(style) && (known.get(owner) || ALL).seen === SHOWS
                && (parent === owner || (known.get(parent) || ALL).seen === SHOWS) && textHasBox(child, owner, style)) ctx.run += child.data;
            }
          } else if (child.nodeType === Node.ELEMENT_NODE) {
            visit(child, out, ctx);
          }
        }
      };
      // An element's contents. One named by its contents (a link, a button, a heading) lists only what's usable in it.
      const usableOnly = (list) => list.flatMap((item) => {
        if (!item.ref) return usableOnly(item.children || []);
        if (item.children) { const kept = usableOnly(item.children); if (kept.length) item.children = kept; else delete item.children; }
        return [item];
      });
      const inside = (el, mute) => {
        const children = [], ctx = { run: '', mute };
        walk(el, children, ctx);
        flush(children, ctx);
        return mute ? usableOnly(children) : children;
      };
      // Whether a name stands for all the element holds, so only usable descendants are listed. Not when cut short (a
      // link around a whole card), nor for a table row, whose cells are what's read.
      const rowOfCells = (role, named) => role === 'row' && !!named.fromContent;
      const saysItAll = (role, named) => !!named.name && !named.partial && !rowOfCells(role, named);
      // The listed name. None for a row, or for an unusable element (a cell, a heading) whose name was cut: the full
      // text is listed under it. A usable element keeps its cut name, as the app is told what it clicked.
      const shownName = (role, named, usable) => rowOfCells(role, named) || (named.partial && !usable)
        ? Object.assign({}, named, { name: '' }) : named;
      // An element's node, with a ref if it's one an app can use.
      const node = (el, role, named, usable, extra, more) => {
        const item = { role: role || 'generic' };
        if (named.name) item.name = named.name;
        const flags = more ? more.slice() : [];
        if (named.labelDiffers) flags.push('labelDiffers');
        if (mixedScripts(named.name)) flags.push('mixedScripts');
        const states = statesOf(el, role);
        if (Object.keys(states).length) item.states = states;
        if (usable) {
          item.ref = refFor(usable);
          refs += 1;
          listed.add(item.ref);
          if (before && !before.has(item.ref)) flags.push('new');
        }
        if (flags.length) item.flags = flags;
        return Object.assign(item, extra || {});
      };
      // At most 400 elements deep: the rest is left out and the snapshot says it's cut.
      let depth = 0, deep = false;
      const visit = (el, out, ctx) => {
        if (depth >= 400) { deep = true; return; }
        depth += 1;
        try { visitElement(el, out, ctx); } finally { depth -= 1; }
      };
      const visitElement = (el, out, ctx) => {
        if (++visited > 20000 || performance.now() - started > 1000) { cut = true; return; }
        const style = styleOf(el);
        const box = el.getBoundingClientRect();
        if (leftOut(el, style, box)) return;
        // What the person sees of it (cached, for its name and its descendants).
        const seen = whatIs(el, true, style, box).seen;
        if (seen === GONE) return;
        // Under a thin box: not listed itself, but something in it may escape that box.
        if (seen === CLIPPED) { walk(el, out, ctx); return; }
        const tag = el.localName;
        if (tag === 'br') { ctx.run += ' '; return; }
        const shows = box.width > 0 && box.height > 0 && style.visibility === 'visible';
        const role = roleOf(el);
        if (tag === 'iframe' || tag === 'frame') {
          if (shows) {
            flush(out, ctx);
            const item = { role: 'iframe' };
            const title = clip(el.getAttribute('title'), 100);
            if (title) item.name = title;
            try { const origin = new URL(el.src, location.href).origin; if (origin && origin !== 'null') item.url = origin; } catch (e) {}
            out.push(item);
          }
          return;
        }
        // A label's words are its field's name, so only what's usable in it is listed (its field, a link to terms). A
        // checkbox or radio the page hides and draws itself is listed at its label, which is what the person clicks.
        if (tag === 'label' && el.control) {
          const control = el.control;
          if (shown(control)) {
            flush(out, ctx);
            out.push(...inside(el, true));
            return;
          }
          if (shows && (control.type === 'checkbox' || control.type === 'radio')) {
            flush(out, ctx);
            out.push(node(control, roleOf(control), nameOf(control), control), ...inside(el, true));
            return;
          }
        }
        const editing = role === 'textbox' && el.isContentEditable;
        const pointer = style.cursor === 'pointer' && !(el.parentElement && styleOf(el.parentElement).cursor === 'pointer');
        const usable = shows && role !== 'presentation'
          && (INTERACTIVE.has(role) || editing || (el.hasAttribute('tabindex') && el.tabIndex >= 0) || el.hasAttribute('onclick') || pointer);
        // A picture or icon: listed when named, with a ref when usable. Its contents aren't read.
        if (tag === 'svg' || role === 'img') {
          const named = nameOf(el);
          if (usable) {
            flush(out, ctx);
            out.push(node(el, role || 'img', named, el, null, pointer && !INTERACTIVE.has(role) ? ['pointer'] : null));
          } else if (shows && role === 'img' && named.name) {
            flush(out, ctx);
            out.push(node(el, 'img', named));
          }
          return;
        }
        const scrolls = shows && el !== document.scrollingElement && el !== document.body
          && ((/(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight + 1) || (/(auto|scroll)/.test(style.overflowX) && el.scrollWidth > el.clientWidth + 1));
        if (usable) {
          flush(out, ctx);
          const extra = {};
          if (tag === 'select') {
            const value = valueOf(el, 100);
            Object.assign(extra, value);
            // The choices on offer; which one is chosen only when the value may be given.
            const options = [...el.options], chosen = value.value !== undefined;
            extra.children = options.slice(0, 30).map((o) => chosen && o.selected ? { role: 'option', name: clip(o.text, 100), states: { selected: true } } : { role: 'option', name: clip(o.text, 100) });
            if (options.length > 30) extra.more = options.length - 30;
          } else if (editing) {
            Object.assign(extra, valueOf(el, 100));
          } else if (VALUED.has(role) && 'value' in el) {
            Object.assign(extra, valueOf(el, 100));
          }
          const url = role === 'link' ? linkURL(el) : null;
          if (url) extra.url = url;
          const named = nameOf(el);
          const item = node(el, role, shownName(role, named, true), el, extra, pointer && !INTERACTIVE.has(role) ? ['pointer'] : null);
          // Contents are listed under it unless its name says it all. A field holds only a value, given above under the
          // value rules.
          if (!isField(el) && !editing) {
            const children = inside(el, saysItAll(role, named));
            if (children.length) item.children = children;
          }
          out.push(item);
          return;
        }
        // A field that doesn't show: nothing of it, least of all the text a page put in it.
        if (isField(el)) return;
        if (scrolls) {
          flush(out, ctx);
          const left = Math.max(0, Math.round(el.scrollHeight - el.clientHeight - el.scrollTop));
          const item = node(el, STRUCTURE.has(role) ? role : 'generic', nameOf(el), el);
          item.states = Object.assign(item.states || {}, { scrollable: left });
          const children = inside(el, false);
          if (children.length) item.children = children;
          out.push(item);
          return;
        }
        if (STRUCTURE.has(role) || (NAMED_ONLY.has(role) && nameOf(el).name)) {
          flush(out, ctx);
          const named = nameOf(el);
          const item = node(el, role, shownName(role, named, false));
          const children = inside(el, saysItAll(role, named) && (role === 'heading' || NAMED_BY_CONTENT.has(role)));
          if (children.length) item.children = children;
          if (item.children || (item.name && (ON_THEIR_OWN.has(role) || NAMED_BY_CONTENT.has(role)))) out.push(item);
          return;
        }
        // Nothing of its own (a div, a span): what it holds, in its place.
        if (INLINE.has(tag) && style.display.startsWith('inline')) {
          walk(el, out, ctx);
        } else {
          flush(out, ctx);
          walk(el, out, ctx);
          flush(out, ctx);
        }
      };
      const nodes = [], ctx = { run: '', mute: false };
      if (root) visit(root, nodes, ctx); else walk(document.body || document.documentElement, nodes, ctx);
      flush(nodes, ctx);
      // A partial snapshot (by ref, or of an open dialog) adds to what was listed. A full one replaces it.
      zz.listed = root && before ? new Set([...before, ...listed]) : listed;
      known = null;
      return { title: clip(document.title, 200), url: String(location.href).slice(0, 2000), nodes, refs, cut: cut || deep, modal: !!modal };
    }
    case 'state':
      return { title: document.title, url: location.href, readyState: document.readyState };
    default:
      return { error: 'Unknown operation.' };
    }
    })();
    if (answer && typeof answer === 'object') {
      answer.refPage = zz.page;
      if (zz.gone && zz.gone.length) { answer.refsGone = zz.gone; zz.gone = []; }
    }
    return answer;
    """#
}

/// The refs apps are given. Each page numbers its own elements (e1, e2…, under a page id), and Zigzag renumbers them
/// with one counter for all tabs. So two tabs never give the same ref, a ref only works on the tab and page it came
/// from, and an element keeps its number while its page lasts.
@MainActor
enum MCPRefs {
    private struct Local: Hashable {
        let view: ObjectIdentifier
        let page: String
        let ref: String
    }

    private struct Owner {
        weak var view: WKWebView?
        let page: String
        let ref: String
    }

    private static var count = 0
    private static var given: [Local: String] = [:]
    private static var owners: [String: Owner] = [:]
    /// Pages each web view gave refs on, latest first. A few are kept, as Back can restore a page as it was.
    private static var pages: [ObjectIdentifier: [String]] = [:]
    private static let pagesKept = 5

    /// How many refs Zigzag holds for a web view's pages (for tests).
    static func held(by view: WKWebView) -> Int { owners.values.filter { $0.view === view }.count }

    /// `args` with a ref in its page's own terms, or why it can't be used on this web view's page.
    static func inbound(_ args: [String: Any], for view: WKWebView) -> Result<[String: Any], MCPArgumentError> {
        guard let shown = args["ref"] as? String else { return .success(args) }
        guard let owner = owners[shown], owner.view === view else {
            return .failure(.init("\(shown) isn’t on this page now: it’s from another tab, or the page changed or loaded again since your snapshot. Take a new snapshot."))
        }
        var args = args
        args["ref"] = owner.ref
        args["refPage"] = owner.page
        args["refShown"] = shown
        return .success(args)
    }

    /// The page's answer with every ref in it swapped for the one apps are given. Refs the page dropped (their elements
    /// left it) are dropped here too.
    static func outbound(_ answer: [String: Any], for view: WKWebView) -> [String: Any] {
        var answer = answer
        let gone = answer.removeValue(forKey: "refsGone") as? [String] ?? []
        guard let page = answer.removeValue(forKey: "refPage") as? String else { return answer }
        remember(page, of: view)
        forget(gone, page: page, of: view)
        return swap(answer, page: page, view: view) as? [String: Any] ?? answer
    }

    private static func forget(_ refs: [String], page: String, of view: WKWebView) {
        guard !refs.isEmpty else { return }
        let id = ObjectIdentifier(view)
        for ref in refs {
            guard let shown = given.removeValue(forKey: Local(view: id, page: page, ref: ref)) else { continue }
            owners[shown] = nil
        }
    }

    private static func swap(_ value: Any, page: String, view: WKWebView) -> Any {
        switch value {
        case var object as [String: Any]:
            for (key, item) in object {
                if key == "ref", let local = item as? String { object[key] = global(local, page: page, view: view) }
                else if item is [String: Any] || item is [Any] { object[key] = swap(item, page: page, view: view) }
            }
            return object
        case let list as [Any]:
            return list.map { swap($0, page: page, view: view) }
        default:
            return value
        }
    }

    private static func global(_ local: String, page: String, view: WKWebView) -> String {
        let key = Local(view: ObjectIdentifier(view), page: page, ref: local)
        if let known = given[key] { return known }
        count += 1
        let ref = "e\(count)"
        given[key] = ref
        owners[ref] = Owner(view: view, page: page, ref: local)
        return ref
    }

    /// Notes a page the web view answered from, latest first. A page past the last few, or a gone web view, takes its
    /// refs with it.
    private static func remember(_ page: String, of view: WKWebView) {
        let id = ObjectIdentifier(view)
        var list = pages[id] ?? []
        guard list.first != page else { return }
        list.removeAll { $0 == page }
        list.insert(page, at: 0)
        let dropped = Set(list.dropFirst(pagesKept))
        pages[id] = Array(list.prefix(pagesKept))
        owners = owners.filter { _, owner in
            guard let other = owner.view else { return false }
            return !(ObjectIdentifier(other) == id && dropped.contains(owner.page))
        }
        let alive = Set(owners.values.compactMap { $0.view.map(ObjectIdentifier.init) })
        given = given.filter { alive.contains($0.key.view) && !($0.key.view == id && dropped.contains($0.key.page)) }
        pages = pages.filter { alive.contains($0.key) || $0.key == id }
    }
}
