import Foundation
import WebKit

/// Where you were on a page and what you'd typed into it, read as you leave its tab, so a page that has to load
/// again (it slept, or its process stopped) comes back there. WebKit's own history does this for a plain page; a page
/// that builds itself with script (a feed, a forum thread) is often still building when WebKit looks, so this tries
/// again for a few seconds as it fills in. Only text you typed into an ordinary field is kept, never a password or
/// card number, and only in memory, until the tab is back.
nonisolated struct PageState: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        /// Where the field is on the page, as a CSS selector.
        let selector: String
        let value: String
    }

    let url: URL
    let scroll: CGPoint
    let fields: [Field]
    /// Something you typed is still there: a field above, or text in an editor (a rich reply box) you wrote in.
    let hasTypedText: Bool
    /// The page puts itself where you were (history.scrollRestoration = "manual"), as a forum that keeps the post
    /// you're reading in its address does: its scrolling is left to it.
    let placesItself: Bool

    init(url: URL, scroll: CGPoint, fields: [Field] = [], hasTypedText: Bool = false, placesItself: Bool = false) {
        self.url = url
        self.scroll = scroll
        self.fields = fields
        self.hasTypedText = hasTypedText || !fields.isEmpty
        self.placesItself = placesItself
    }

    /// From what `reader` returns.
    init?(_ result: Any?, url: URL?) {
        guard let url, let result = result as? [String: Any] else { return nil }
        let fields = (result["fields"] as? [[String]] ?? []).compactMap { $0.count == 2 ? Field(selector: $0[0], value: $0[1]) : nil }
        self.init(url: url, scroll: CGPoint(x: result["x"] as? Double ?? 0, y: result["y"] as? Double ?? 0), fields: fields,
                  hasTypedText: result["typed"] as? Bool ?? false, placesItself: result["manual"] as? Bool ?? false)
    }

    /// Whether this is the page now loaded: the same address, give or take its #fragment.
    func belongs(to url: URL?) -> Bool {
        guard let url else { return false }
        func bare(_ url: URL) -> String { url.absoluteString.components(separatedBy: "#")[0] }
        return bare(url) == bare(self.url)
    }

    /// The arguments `restorer` takes.
    var restoreArguments: [String: Any] {
        ["x": Double(scroll.x), "y": placesItself ? 0.0 : Double(scroll.y), "fields": fields.map { [$0.selector, $0.value] }]
    }

    /// Notes which fields you typed into (the page's own script filling one in doesn't count). In Zigzag's own
    /// world, so the page can't see it.
    @MainActor static let script = WKUserScript(source: """
    (() => {
      const typed = window.__zigzagTyped = new Set();
      // A field that was a password while you typed stays secret once "Show password" makes it plain text.
      const secret = window.__zigzagSecret = new WeakSet();
      addEventListener('input', (e) => {
        if (!e.isTrusted || !(e.target instanceof Element)) return;
        if (e.target instanceof HTMLInputElement && e.target.type === 'password') secret.add(e.target);
        typed.add(e.target);
      }, true);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)

    /// Which fields' text may be kept: a text area, or a plain text field, that isn't a password (or wasn't one while
    /// you typed), a card's details, a one-time code or the like, by its type, its autocomplete, its name and label,
    /// or text the page hides as it's typed.
    static let fieldRules = """
      const kinds = new Set(['text', 'search', 'email', 'url', 'tel', 'number']);
      const secretWords = /pass|pwd|cc-|card|cvc|cvv|csc|security.?code|one.?time|otp|totp|2fa|mfa|verif|pin(?![a-z])|ssn|social.?security|iban|routing|account.?num|secret|token/i;
      const keepable = (el) => {
        const plain = el instanceof HTMLTextAreaElement || (el instanceof HTMLInputElement && kinds.has(el.type));
        if (!plain || window.__zigzagSecret?.has(el)) return false;
        const said = [el.autocomplete, el.name, el.id, el.getAttribute('aria-label'), el.placeholder].join(' ');
        if (secretWords.test(said)) return false;
        const hidden = getComputedStyle(el).getPropertyValue('-webkit-text-security');
        return !hidden || hidden === 'none';
      };
    """

    /// Reads the page's scroll and what you typed, as an object `init?(_:url:)` reads.
    static let reader = """
    (() => {
    \(fieldRules)
      const path = (el) => {
        const parts = [];
        for (let e = el; e && e !== document.documentElement; e = e.parentElement) {
          if (e.id && document.querySelectorAll('#' + CSS.escape(e.id)).length === 1) { parts.unshift('#' + CSS.escape(e.id)); break; }
          let i = 1;
          for (let s = e.previousElementSibling; s; s = s.previousElementSibling) if (s.localName === e.localName) i++;
          parts.unshift(e.localName + ':nth-of-type(' + i + ')');
        }
        return parts.join(' > ');
      };
      const fields = [];
      let size = 0, editing = false;
      for (const el of window.__zigzagTyped || []) {
        if (!el.isConnected) continue;
        if (el.isContentEditable) { if (el.innerText.trim()) editing = true; continue; }
        if (!keepable(el) || !el.value || el.value === el.defaultValue) continue;
        if (fields.length >= 30 || size + el.value.length > 200000) break;
        size += el.value.length;
        fields.push([path(el), el.value]);
      }
      return { x: scrollX, y: scrollY, fields, typed: editing, manual: history.scrollRestoration === 'manual' };
    })()
    """

    /// Puts the page back: what you typed into fields that are empty again, and the scroll, unless the page has put
    /// itself somewhere or you've scrolled or typed since. Tried again as the page builds, for up to five seconds.
    static let restorer = """
    \(fieldRules)
    let moved = false;
    const stop = () => { moved = true; };
    for (const kind of ['wheel', 'keydown', 'mousedown', 'touchstart']) addEventListener(kind, stop, { capture: true, once: true });
    const setter = (el) => Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
    let left = fields.slice(), scrolled = y < 1 && x < 1, lastY = scrollY;
    for (let i = 0; i < 20 && !(scrolled && left.length === 0); i++) {
      left = left.filter(([selector, value]) => {
        let el = null;
        try { el = document.querySelector(selector); } catch (e) { return false; }
        if (!el) return true;
        // The page changed since and something else is there now (a password field, a card number): left alone.
        if (!keepable(el)) return false;
        if (el.value === '' || el.value === el.defaultValue) {
          setter(el)?.call(el, value);
          el.dispatchEvent(new Event('input', { bubbles: true }));
        }
        // Still yours: it counts as typed, so it's kept if the page has to load again.
        if (el.value === value) window.__zigzagTyped?.add(el);
        return false;
      });
      if (!scrolled) {
        // The page moved on its own, or you did: it's where it should be.
        if (moved || (i > 0 && Math.abs(scrollY - lastY) > 1)) scrolled = true;
        else {
          scrollTo(x, y);
          if (Math.abs(scrollY - y) < 2 && Math.abs(scrollX - x) < 2) scrolled = true;
        }
      }
      lastY = scrollY;
      await new Promise((r) => setTimeout(r, 250));
    }
    return { scrolled, left: left.length };
    """
}
