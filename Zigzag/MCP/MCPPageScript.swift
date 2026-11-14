import WebKit

/// What the tools do inside a page: run in a content world of Zigzag's own, so the page's scripts can't see it, stand
/// in for it or change what it reports. It reads the DOM and acts on it; it never runs anything an app sends.
enum MCPPageScript {
    static let world = WKContentWorld.world(name: "app.zigzag.mcp")

    /// From the start of every page, in this world: which fields were passwords while the person typed in them, so
    /// PageState's rules keep one secret after a site's "Show password" makes it plain text.
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
    // Zigzag's own notes in the page, in this world so the page can't see them: the fields the agent typed into, and
    // the refs it was given for elements, each with what it stood for.
    // The page's own refs and its id: Zigzag gives apps refs of its own for them (MCPRefs).
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
    // A value no app is given: a password, a card's details, a one-time code and the like (the rules that keep them out
    // of what a tab remembers, PageState.fieldRules), a hidden input's, or a card number in any field. A list or a
    // rich-text field is judged by what it says it holds, as a text field is, and by the words it shows.
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
    // What a field holds, before any rule: a list's choice, a rich-text field's words that show, a field's value.
    const rawValue = (el) => {
      if (el instanceof HTMLSelectElement) return el.selectedOptions.length ? el.selectedOptions[0].text : '';
      if (editingHost(el)) return textOf(el);
      return String(el.value ?? '');
    };
    // What the person's saved details fill in (their name, email, phone, address): an app is told only that it's filled,
    // and how long, unless it typed the value itself.
    const personal = /\b(name|honorific-prefix|given-name|additional-name|family-name|honorific-suffix|nickname|email|tel(-[a-z-]+)?|street-address|address-line[123]|address-level[1-4]|postal-code|country(-name)?|bday(-[a-z]+)?|organization(-title)?)\b/i;
    const autofilled = (el) => {
      for (const state of [':autofill', ':-webkit-autofill']) { try { if (el.matches(state)) return true; } catch (e) {} }
      return false;
    };
    const savedDetail = (el) => personal.test(el.getAttribute('autocomplete') || '') || autofilled(el);
    // Characters that change how text reads without showing: controls, direction marks, zero-width characters, soft
    // hyphens and Unicode tags, the ways hidden instructions ride along in page text.
    const unseen = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u00AD\u061C\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]|[\u{E0000}-\u{E007F}]/gu;
    const clip = (s, n) => {
      s = String(s ?? '').replace(unseen, '').replace(/\s+/g, ' ').trim();
      if (s.length <= n) return s;
      const chars = [...s];
      return chars.length > n ? chars.slice(0, n).join('') + '…' : s;
    };
    // A field's value as an app may have it, in one order for every kind of field: none for a password or a secret,
    // only its length for a saved detail the app didn't type itself, otherwise the value (a list's choice, a rich-text
    // field's words).
    const valueOf = (el, max) => {
      if (isSecret(el)) return { password: true };
      const value = rawValue(el);
      // What the app typed itself, while the field still holds exactly that, is no secret from it. Never a
      // password, shown or not.
      const typedIt = value !== '' && zz.typed.get(el) === value && !(globalThis.__zigzagSecret && globalThis.__zigzagSecret.has(el));
      if (!typedIt && sensitive(el)) return { secret: true };
      if (value && !typedIt && savedDetail(el)) return { filled: [...value].length };
      return { value: clip(value, max) };
    };
    // A field: a box of its own, holding a value and none of the page's text.
    const isField = (el) => el.localName === 'input' || el.localName === 'textarea' || el.localName === 'select';
    // What a clip-path's inset() leaves: nothing, when its top and bottom (or left and right) meet. One to four
    // values, as CSS fills them in; any it can't read (a calc()) counts as leaving something.
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
    // Clipped to nothing, the "visually hidden" way: a clip or clip-path that leaves none of it, or a box of a pixel
    // or less that hides what overflows it.
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
    // A thin box: under 4 points (thinner than text is read at, readableStyle) on a side it clips. It shows nothing
    // of what it holds, whichever way that's shifted; the box itself is still there (a seek bar 3 points high is
    // seen, and clicked). Not an inline element, which clips nothing, nor a field, which holds nothing to clip.
    const thin = (el, style, box) => (box.width < 4 || box.height < 4) && !isField(el) && style.display !== 'inline'
      && ((box.width < 4 && style.overflowX !== 'visible') || (box.height < 4 && style.overflowY !== 'visible'));
    // Shrunk to nothing, the "scale(0)" way: by what the transform does (its matrix), so one that only moves or
    // turns something is never taken for it.
    const flattened = (style) => {
      const scale = style.scale;
      if (scale && scale !== 'none' && scale.split(/\s+/).slice(0, 2).some((n) => Math.abs(parseFloat(n)) < 0.01)) return true;
      const transform = style.transform;
      if (!transform || transform === 'none') return false;
      const n = (transform.slice(transform.indexOf('(') + 1).match(/-?[\d.]+(?:e-?\d+)?/g) || []).map(Number);
      const [a, b, c, d] = transform.startsWith('matrix3d') ? [n[0], n[1], n[4], n[5]] : n;
      return Math.hypot(a, b) < 0.01 || Math.hypot(c, d) < 0.01;
    };
    // Outside anything the page can be scrolled to, sideways: a page read right to left scrolls the other way.
    const offSideways = (box) => {
      const page = document.scrollingElement || document.documentElement;
      // The page scrolls as its root reads, or its body: the body's direction is the window's too.
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
    // Parked out of sight, the "left: -9999px" way: positioned outside anything that can be scrolled to (a fixed
    // element, outside the window). What's in the page's flow is never parked: past the end of a scrolling list, it's
    // still there to scroll to.
    const parked = (style, box) => {
      if (style.position === 'fixed') return box.right <= 0 || box.bottom <= 0 || box.left >= innerWidth || box.top >= innerHeight;
      return style.position === 'absolute' && offPage(box);
    };
    // Tucked away with all it holds: every way a page hides something from people while leaving it in the page, in
    // one place for whatever asks (a name, a click, a snapshot). What's shrunk to nothing has a box that says so:
    // only then is its transform read.
    const tuckedAway = (el, style, box) => clipsAway(el, style, box) || ((box.width < 4 || box.height < 4) && flattened(style)) || parked(style, box);
    // So faint it's as good as see-through.
    const faint = (style) => { const opacity = style.opacity; return opacity !== '1' && parseFloat(opacity) < 0.1; };
    const host = (node) => node.parentElement || (node.parentNode && node.parentNode.host) || null;
    // Where a node is drawn: in the slot a web component gives it to, if it does, else in what holds it. What's
    // above it on the page, for whether it's seen, is what's above that.
    const drawnIn = (node) => node.assignedSlot || host(node);
    // Up and into, through shadow roots: what holds a node as the page is put together, and whether one holds another.
    const composedParent = (node) => node.parentNode instanceof ShadowRoot ? node.parentNode.host : node.parentNode;
    const composedContains = (outer, node) => {
      for (let at = node; at; at = composedParent(at)) if (at === outer) return true;
      return false;
    };
    // Whether an element placed apart (fixed, absolute) is painted outside the strip a thin box above it leaves: asked
    // of WebKit, which knows whether that box clips it (whether it's its containing block, by any of the ways CSS
    // has), with a hit at a point of the element's box beyond the strip. Hit there, it's there to see. A point
    // outside the window can't be asked, and isn't taken for a yes.
    // Hit tests asked for in this call: a collapsed box can hold hundreds of placed rows, and past a fair number
    // the rest aren't asked about, which is a no.
    let hitTests = 0;
    const paintedBeyond = (el, box, strip) => {
      const root = el.getRootNode(), from = root.elementsFromPoint ? root : document;
      // Hit itself, or in something it holds that isn't placed apart in its turn (that one's answer is its own).
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
    // What the person sees of an element, said one way for whoever asks (a name, a click, a snapshot), from what it
    // is itself and what the one above it is:
    //   GONE     not seen, nor anything in it: see-through, tucked away, or under something that is
    //   CLIPPED  under a thin box and outside the strip it leaves; something in it may still escape that box
    //   BOX      its box shows, the text right in it doesn't: a thin box itself, or something over a thin box's strip
    //   SHOWS    all of it
    // With CLIPPED and BOX comes the strip in force (`strip`: its edges), for what's below. `opacity`: see-through
    // counts as gone (a click's reach looks past it). Not asked here: whether it's drawn at all (checkVisibility,
    // which whoever asks does first).
    const GONE = 0, CLIPPED = 1, BOX = 2, SHOWS = 3;
    const ALL = { seen: SHOWS, strip: null }, NONE = { seen: GONE, strip: null };
    const under = (el, style, box, above, opacity) => {
      if (above.seen === GONE) return NONE;
      // No box of its own: as what holds it.
      if (style.display === 'contents') return above;
      if (tuckedAway(el, style, box) || (opacity && faint(style))) return NONE;
      let seen = SHOWS, strip = above.strip;
      if (strip) {
        // Placed apart and painted beyond the strip: the thin box doesn't clip it, and it's as if not under it.
        if ((style.position === 'fixed' || style.position === 'absolute') && paintedBeyond(el, box, strip)) strip = null;
        // Over the strip, its box is there (a fill in a thin track): never a field, whose value would be read
        // though it's clipped like any text.
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
    // The answer for an element: `under`, from the top of the page down to it. Up first, one at a time (never by
    // recursion: a page can nest as deep as it likes), then back down. `style`, `box`: the element's own, when
    // whoever asks has them already.
    const whatIs = (e, opacity, style, box) => {
      const chain = [];
      for (let at = e; at && at !== document.body && at !== document.documentElement; at = drawnIn(at)) chain.push(at);
      let above = ALL;
      for (let i = chain.length - 1; i >= 0; i--) {
        const at = chain[i];
        above = above.seen === GONE ? NONE
          : under(at, at === e && style ? style : getComputedStyle(at), at === e && box ? box : at.getBoundingClientRect(), above, opacity);
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
    // Where the person's pointer could reach it, seen or not: an invisible input laid over a picture of one is what a
    // real click hits.
    const hittable = (el) => visibleBox(el, false) >= BOX;
    const alpha = (color) => {
      const m = /rgba?\(([^)]*)\)/.exec(color || '');
      if (!m) return 1;
      const parts = m[1].split(/[\s,\/]+/).filter(Boolean);
      return parts.length > 3 ? parseFloat(parts[3]) : 1;
    };
    // Text the person can read: on an element that shows, at least 4 points high, and not see-through (unless it's
    // drawn by its background, as gradient headings are).
    const readableStyle = (style) => parseFloat(style.fontSize) >= 4
      && (alpha(style.webkitTextFillColor || style.color) > 0 || /text/.test(style.webkitBackgroundClip || style.backgroundClip || ''));
    // What could keep an element's text from being seen once a text-indent pushes it: everything above it that
    // clips sideways. Null when the indent can't push text out at all (only backwards, or by the width of what
    // it's set in and more, can): a saving, for the paragraphs of an indented article. Kept for the call, as names
    // are: every text node of an element asks.
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
    // The reach, sideways, of something that clips: its box, or all it can be scrolled to if it scrolls.
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
    // Whether a piece of text is drawn on the page, where its element's style can't say: text pushed by a
    // text-indent (the "image replacement" way) off the page, or out of something that clips it; and text of an
    // element a page draws itself, which a shadow root it keeps closed may leave out. Text right inside a details
    // that's closed never is: WebKit has a box for it all the same, so there's no asking (an element there is
    // asked, checkVisibility). Anything else is drawn where its element is.
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
      // Pushed, it's seen where it can still be: on the page, and within each thing above that clips sideways.
      // Sticking out of what lets it (a number hung in the margin) is seen like any text.
      const within = clips.map(reachOf);
      return boxes.some((box) => !offSideways(box) && within.every(([left, right]) => box.right > left && box.left < right));
    };
    const fold = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();

    // Roles, as screen readers have them: the one a page gives, if it's one they know, or the element's own.
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
      // Where rich-text editing starts is a field, whatever element the page made it of (a list item, a heading).
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
    // An element's text, as a name takes it: only what the person can read, unless `hidden` (what a label points at),
    // with a field inside it giving its value, an image its alt, and never `skip` (the field a label is for).
    // `textOf.cut`: the last text asked for was longer than a name holds, so it isn't all there.
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
          // Only a value that shows, as screen readers take it: what's typed in a field, a slider's, a list's choice.
          // A checkbox's or a radio's value is the page's own word for it, never seen.
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
    // An element's name, in the order screen readers take it (aria-labelledby, aria-label, its label, its text, its
    // title), with two departures that keep words the person can't see from an agent: a name from text only takes
    // text that shows, and when a page labels something differently from what it shows, the shown text wins.
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
      // An icon with no words of its own is named by its SVG's title, as aria-label would name it.
      if (!name && (INTERACTIVE.has(role) || role === 'img' || el.localName === 'svg' || el.hasAttribute('tabindex'))) {
        const title = el.localName === 'svg' ? el.querySelector(':scope > title') : el.querySelector('svg > title');
        if (title) name = clip(title.textContent, 100);
      }
      if (!name && (INTERACTIVE.has(role) || el.hasAttribute('tabindex'))) name = clip(el.getAttribute('title') || el.getAttribute('placeholder') || '', 100);
      // What shows wins over a label that says something else, when what shows is words. A sign alone (×, +, ›) is an
      // icon, and the label is its name, as for a button that shows nothing.
      const words = /[\p{L}\p{N}]/u.test(seen);
      const named = authored && words && !fold(authored).includes(fold(seen)) ? { name: seen, labelDiffers: true } : { name };
      // Named by the text it holds, and whether that name holds all of it: a snapshot lists the rest under it.
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
    // What a ref stands for. If any of it changes, so does the ref: an old ref can't act on something else.
    const printOf = (el) => [roleOf(el) || el.localName, nameOf(el).name, el.getAttribute('href') || '', el.type || ''].join('\u0001');
    const said = (el) => {
      const name = nameOf(el).name;
      return (roleOf(el) || el.localName) + (name ? ' ' + JSON.stringify(name) : '');
    };
    // Every so often, the refs to what's left the page are let go of (resolve refuses them anyway), here and, through
    // refsGone in the answer, in Zigzag (MCPRefs), so a page that lives long doesn't pile them up.
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
      // As it was, it's gone: its old ref is let go, here and (told with the answer) on Zigzag's side.
      if (known) { zz.byRef.delete(known); (zz.gone || (zz.gone = [])).push(known); }
      const ref = 'e' + (++zz.next);
      if (zz.next % 500 === 0) letGo();
      zz.byEl.set(el, ref);
      zz.byRef.set(ref, { el: new WeakRef(el), print, was: said(el) });
      return ref;
    };
    // An element as the tools name it back: its ref, its role and name as a screen reader has them, and a selector.
    const describe = (el) => ({ ref: refFor(el), role: roleOf(el) || el.localName, name: nameOf(el).name, tag: el.localName, selector: selectorFor(el) });
    // The element a tool is given: by ref (still the element it was, as it was), by CSS selector, or by the text it
    // shows (something clickable). Never a guess from a ref's role or name. { el } or { error }.
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
    // The open dialog on top, which has the person's attention: the one holding the focus (showModal() puts it there,
    // and what's under the top dialog is inert, so it can't be anywhere else), looking through shadow roots; otherwise
    // the last one open in the page.
    const topModal = () => {
      const isModal = (el) => { try { return el.localName === 'dialog' && el.matches(':modal'); } catch (e) { return false; } };
      for (let at = deepActive(); at; at = composedParent(at)) if (at.nodeType === Node.ELEMENT_NODE && isModal(at)) return at;
      const open = document.querySelectorAll('dialog:modal');
      return open.length ? open[open.length - 1] : null;
    };
    // Set aside, as the person finds it: inside something the page made inert, or outside the dialog on top (all of
    // which is inert while it's open), looking through shadow roots on the way up.
    const setAside = (el) => {
      const modal = topModal();
      let inModal = !modal;
      for (let at = el; at; at = composedParent(at)) {
        if (at.nodeType === Node.ELEMENT_NODE && at.hasAttribute('inert')) return true;
        if (at === modal) inModal = true;
      }
      return !inModal;
    };
    // What keeps the person from using an element at all, by pointer or keyboard: it's disabled (itself, by what
    // holds it, or by the page's word), or set aside (inert, or behind an open dialog). { error } or null.
    const blocked = (el, who) => {
      if (el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true') return { error: 'That element is disabled.' };
      if (setAside(el)) return { error: who + ' can’t be used now: something else on the page (a dialog) has the person’s attention.' };
      return null;
    };
    // Where keys meant for an element go: in rich text, to where its editing starts (a paragraph of an editor
    // can't take the focus, its editor does); anywhere else, to the element.
    const keysGoTo = (el) => {
      let at = el;
      if (el.isContentEditable && !isField(el)) while (!editingHost(at) && at.parentElement) at = at.parentElement;
      return at;
    };
    // Gives the element the keyboard, as the person's click or Tab would, and says whether it took it: WebKit gives
    // the focus to nothing hidden, disabled or inert. Seen or not: the field a code editor types into isn't. The
    // last thing before keys go, once nothing else can refuse: it scrolls the page and moves the focus.
    // { error } or null.
    const focused = (el, who) => {
      const target = keysGoTo(el);
      const holds = () => { const now = deepActive(); return now === target || target.contains(document.activeElement) || !!(target.shadowRoot && target.shadowRoot.contains(now)); };
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      // Already in it (the caret in an editor): left where it is.
      if (!holds() && typeof target.focus === 'function') target.focus({ preventScroll: true });
      return holds() ? null : { error: who + ' can’t take the keyboard focus, so keys would go somewhere else.' };
    };
    // Whether a click would reach the element as the person's would: nothing keeps them from it, it shows, and
    // nothing covers it, once scrolled into view. A checkbox or radio a page hides and draws itself is clicked
    // through its label, as the person does. { target, x, y } or { error }.
    const reachable = (el, who) => {
      const stop = blocked(el, who);
      if (stop) return stop;
      let target = el;
      if (!hittable(el)) {
        const label = el.labels && [...el.labels].find(shown);
        if (!label) return { error: who + ' is on the page but doesn’t show, so it can’t be clicked.' };
        target = label;
      }
      // At once, whatever the page's own scroll-behavior: where it is now is where the click is checked and lands.
      target.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      // Each of its boxes in the window in turn (a link over two lines has two, and the middle of both may be on
      // neither): the first with nothing over its middle is where the click goes.
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
      // Everything that can refuse comes before the focus moves: a refused call leaves the page as it was.
      const who = shownRef || 'That field';
      // A piece of a rich-text field (a paragraph of an editor) isn't a field: typing goes to the whole of it, and
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
        // All of it is the app's own when it replaced what was there, or added to what was its own already (or to
        // nothing). Added to anything else, it's no longer only the app's.
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

/// The refs apps are given. Each page numbers the elements it hands out in its own way (e1, e2… for that page, with
/// an id of its own); these are Zigzag's numbers for them, one counter for every tab. So two tabs never hand out the
/// same ref, a ref is only taken back on the tab and page it came from, and an element keeps its number while its page
/// lasts.
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
    /// The pages each web view gave refs on, latest first. A few are kept: Back can bring a page back as it was.
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

    /// The page's answer with each of its refs, wherever it is, swapped for the one apps are given. The refs the page
    /// let go of (to what's left it) are let go of here too.
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

    /// A page the web view answered from: the latest first. A page that goes out of the last few, or a web view that's
    /// gone, takes its refs with it.
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
