import Foundation
import WebKit

/// Where you were on a page and what you'd typed into it, read as you leave its tab, so a page that has to load
/// again (it slept, or its process stopped) comes back there. WebKit's own history does this for a plain page; a page
/// that builds itself with script (a feed, a forum thread) is often still building when WebKit looks, so this tries
/// again for a few seconds as it fills in. Only text you typed into an ordinary field is kept, never a password or
/// card number, and only in memory, until the tab is back. A tab put to sleep also keeps its page's sessionStorage,
/// in memory the same way (`session`).
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
    /// The page handles its own scrolling (history.scrollRestoration = "manual"), as a forum that keeps the post
    /// you're reading in its address does: it's given a moment to put itself there, and only a page that stays at
    /// the top (a topic list, which never does) is scrolled back for it.
    let placesItself: Bool
    /// The page's sessionStorage, read only as the tab goes to sleep (`sleepReader`): it goes with the web view, and a
    /// site that keeps you signed in there would ask you to sign in again (#502). Put back by `sessionRestorer`.
    let session: Session?

    struct Session: Equatable, Sendable {
        let origin: String
        let items: [[String]]
    }

    init(url: URL, scroll: CGPoint, fields: [Field] = [], hasTypedText: Bool = false, placesItself: Bool = false,
         session: Session? = nil) {
        self.url = url
        self.scroll = scroll
        self.fields = fields
        self.hasTypedText = hasTypedText || !fields.isEmpty
        self.placesItself = placesItself
        self.session = session
    }

    /// The same, without the sessionStorage: once it's been handed on, or its site's data was cleared.
    var withoutSession: PageState {
        PageState(url: url, scroll: scroll, fields: fields, hasTypedText: hasTypedText, placesItself: placesItself)
    }

    /// From what `reader` returns.
    init?(_ result: Any?, url: URL?) {
        guard let url, let result = result as? [String: Any] else { return nil }
        let fields = (result["fields"] as? [[String]] ?? []).compactMap { $0.count == 2 ? Field(selector: $0[0], value: $0[1]) : nil }
        let stored = result["session"] as? [String: Any]
        let session = (stored?["origin"] as? String).flatMap { origin in
            (stored?["items"] as? [[String]]).map { Session(origin: origin, items: $0.filter { $0.count == 2 }) }
        }
        self.init(url: url, scroll: CGPoint(x: result["x"] as? Double ?? 0, y: result["y"] as? Double ?? 0), fields: fields,
                  hasTypedText: result["typed"] as? Bool ?? false, placesItself: result["manual"] as? Bool ?? false,
                  session: session?.items.isEmpty == false ? session : nil)
    }

    /// Whether this is the page now loaded: the same address, give or take its #fragment.
    func belongs(to url: URL?) -> Bool {
        guard let url else { return false }
        func bare(_ url: URL) -> String { url.absoluteString.components(separatedBy: "#")[0] }
        return bare(url) == bare(self.url)
    }

    /// The arguments `restorer` takes.
    var restoreArguments: [String: Any] {
        ["x": Double(scroll.x), "y": Double(scroll.y), "waits": placesItself, "fields": fields.map { [$0.selector, $0.value] }]
    }

    /// A field that was a password while typed stays secret once "Show password" makes it plain text. `fieldRules`
    /// reads the fields noted, also in the world AI apps read pages in (MCPPageScript.watch).
    static let secretWatch = """
      const secret = window.__zigzagSecret = new WeakSet();
      addEventListener('input', (e) => {
        if (e.isTrusted && e.target instanceof HTMLInputElement && e.target.type === 'password') secret.add(e.target);
      }, true);
    """

    /// Notes which fields you typed into (the page's own script filling one in doesn't count). In Zigzag's own
    /// world, so the page can't see it.
    @MainActor static let script = WKUserScript(source: """
    (() => {
    \(secretWatch)
      const typed = window.__zigzagTyped = new Set();
      addEventListener('input', (e) => {
        if (!e.isTrusted || !(e.target instanceof Element)) return;
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
      // What a field says it holds, by its autocomplete, name, id, label or placeholder, is a secret.
      const secretSaid = (el) => secretWords.test([el.autocomplete, el.name, el.id, el.getAttribute('aria-label'), el.placeholder]
        .filter((part) => typeof part === 'string').join(' '));
      const keepable = (el) => {
        const plain = el instanceof HTMLTextAreaElement || (el instanceof HTMLInputElement && kinds.has(el.type));
        if (!plain || window.__zigzagSecret?.has(el)) return false;
        if (secretSaid(el)) return false;
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

    /// `reader`, and the page's sessionStorage too, for a tab going to sleep. Not Zigzag's own Dark Reader cache,
    /// which builds itself again, and nothing when the rest is more than one page script should carry (#178).
    static let sleepReader = """
    Object.assign(\(reader), { session: (() => {
      try {
        if (location.origin === 'null') return null;
        const items = [];
        let stored = 0;
        for (let i = 0; i < sessionStorage.length; i++) {
          const key = sessionStorage.key(i);
          if (key.startsWith('__darkreader__')) continue;
          const value = sessionStorage.getItem(key) ?? '';
          stored += key.length + value.length;
          if (stored > 250000) return null;
          items.push([key, value]);
        }
        return items.length ? { origin: location.origin, items } : null;
      } catch (e) { return null; }
    })() })
    """

    /// Marks `sessionRestorer`'s script.
    static let sessionMark = "/* zigzag: sessionStorage of a woken tab */"

    /// What `sessionRestorer` says once it has run on its origin, to Zigzag's world only (`SessionRestored`).
    static let sessionMessage = "zigzagSessionRestored"

    /// Puts `session` back into the page's sessionStorage as it starts, before the page's own scripts run: only on
    /// its origin, and never over a key already there. Done, it says so, and the tab takes it out; a page on another
    /// origin (a sign-in page the woken one sends you to) leaves it for the page you come back to.
    @MainActor static func sessionRestorer(_ session: Session) -> WKUserScript? {
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        guard let origin = try? JSONSerialization.data(withJSONObject: session.origin, options: options),
              let items = try? JSONSerialization.data(withJSONObject: session.items, options: options) else { return nil }
        return WKUserScript(source: """
        \(sessionMark)
        (() => {
          if (location.origin !== \(String(decoding: origin, as: UTF8.self))) return;
          try {
            for (const [key, value] of \(String(decoding: items, as: UTF8.self))) {
              if (sessionStorage.getItem(key) === null) sessionStorage.setItem(key, value);
            }
          } catch (e) {}
          try { window.webkit.messageHandlers.\(sessionMessage).postMessage(true); } catch (e) {}
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }

    /// Puts the page back: what you typed into fields that are empty again, and the scroll, unless the page has put
    /// itself somewhere or you've scrolled or typed since. Tried again as the page builds, for up to five seconds.
    /// `waits`: a page that does its own scrolling gets a second and a half to put itself somewhere first.
    static let restorer = """
    \(fieldRules)
    const waitFor = waits ? 6 : 0;
    let moved = false;
    const stop = () => { moved = true; };
    // Passive: a wheel listener that could cancel makes WebKit wait for the page before it scrolls.
    for (const kind of ['wheel', 'keydown', 'mousedown', 'touchstart']) addEventListener(kind, stop, { capture: true, once: true, passive: true });
    const setter = (el) => Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
    let left = fields.slice(), scrolled = y < 1 && x < 1, lastY = scrollY;
    for (let i = 0; i < 20 + waitFor && !(scrolled && left.length === 0); i++) {
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
        // Its own scrolling took it somewhere already (the post you were reading).
        else if (waitFor && i <= waitFor && Math.abs(scrollY) > 1) scrolled = true;
        else if (i >= waitFor) {
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

/// Hears `PageState.sessionRestorer` say it has run, so its tab takes it out before any later page can get it.
@MainActor final class SessionRestored: NSObject, WKScriptMessageHandler {
    static let shared = SessionRestored()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let tab = (message.webView as? BrowserWebView)?.owner else { return }
        tab.sessionRestored()
    }
}
