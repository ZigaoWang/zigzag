import WebKit

/// What the tools do inside a page: run in a content world of Zigzag's own, so the page's scripts can't see it, stand
/// in for it or change what it reports. It reads the DOM and acts on it; it never runs anything an app sends.
enum MCPPageScript {
    static let world = WKContentWorld.world(name: "app.zigzag.mcp")

    /// Runs `op` with `args` in the page's main frame. The page's answer, or an error message.
    static func run(_ op: String, _ args: [String: Any] = [:], in webView: WKWebView) async -> Result<[String: Any], MCPArgumentError> {
        do {
            let value = try await webView.callAsyncJavaScript(body, arguments: ["op": op, "args": args], in: nil, contentWorld: world)
            guard let object = value as? [String: Any] else { return .failure(.init("The page gave no answer.")) }
            if let error = object["error"] as? String { return .failure(.init(error)) }
            return .success(object)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            return .failure(.init(message.map { "The page couldn't do it: \($0)" } ?? "The page couldn't do it."))
        }
    }

    /// The function's body; `op` and `args` are its arguments.
    static let body = #"""
    const isSecret = (el) => {
      const type = (el.getAttribute && el.getAttribute('type') || '').toLowerCase();
      const ac = (el.getAttribute && el.getAttribute('autocomplete') || '').toLowerCase();
      return type === 'password' || (el.type || '').toLowerCase() === 'password' || ac.includes('password');
    };
    const hidesValue = (el) => {
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
      return isSecret(el) || (el.type || '').toLowerCase() === 'hidden' || ['cc-number', 'cc-csc', 'one-time-code'].some((w) => ac.includes(w));
    };
    const shown = (el) => {
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return false;
      const s = getComputedStyle(el);
      return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
    };
    const clip = (s, n) => { s = (s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n) + '…' : s; };
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
    const labelOf = (el) => {
      if (el.labels && el.labels.length) return clip(el.labels[0].innerText, 120);
      return clip(el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || '', 120);
    };
    const describe = (el) => {
      const text = clip(el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('alt') || '', 120);
      return { tag: el.tagName.toLowerCase(), text, selector: selectorFor(el) };
    };
    const find = (selector) => {
      try { return document.querySelector(selector); } catch (e) { throw new Error('Invalid CSS selector: ' + selector); }
    };

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
        const field = { selector: selectorFor(el), tag: el.tagName.toLowerCase(), type, label: labelOf(el), name: el.getAttribute('name') || '' };
        if (isSecret(el)) field.password = true;
        if (!hidesValue(el)) {
          if (el.tagName === 'SELECT') {
            field.value = el.selectedOptions.length ? clip(el.selectedOptions[0].text, 200) : '';
            field.options = [...el.options].slice(0, 50).map((o) => clip(o.text, 80));
          } else if (type === 'checkbox' || type === 'radio') {
            field.checked = el.checked;
          } else {
            field.value = clip(el.value, 500);
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
      let el = null;
      if (args.selector) {
        el = find(args.selector);
        if (!el) return { error: 'Nothing on the page matches ' + args.selector + '.' };
      } else {
        const want = args.text.replace(/\s+/g, ' ').trim().toLowerCase();
        const candidates = [...document.querySelectorAll('a, button, input[type=button], input[type=submit], input[type=reset], [role=button], [role=link], [role=tab], [role=menuitem], [role=option], [role=checkbox], summary, label, [onclick]')]
          .filter(shown);
        const textOf = (c) => (c.innerText || c.value || c.getAttribute('aria-label') || c.getAttribute('title') || '').replace(/\s+/g, ' ').trim().toLowerCase();
        el = candidates.find((c) => textOf(c) === want) || candidates.find((c) => textOf(c).includes(want));
        if (!el) return { error: 'Nothing clickable on the page says “' + args.text + '”.' };
      }
      if (el.disabled) return { error: 'That element is disabled.' };
      el.scrollIntoView({ block: 'center', inline: 'center' });
      const r = el.getBoundingClientRect();
      const at = { bubbles: true, cancelable: true, composed: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
      for (const kind of ['pointerdown', 'mousedown']) el.dispatchEvent(new (kind.startsWith('pointer') && window.PointerEvent ? PointerEvent : MouseEvent)(kind, at));
      if (typeof el.focus === 'function') el.focus({ preventScroll: true });
      for (const kind of ['pointerup', 'mouseup']) el.dispatchEvent(new (kind.startsWith('pointer') && window.PointerEvent ? PointerEvent : MouseEvent)(kind, at));
      el.click();
      return { clicked: describe(el) };
    }
    case 'type': {
      const el = find(args.selector);
      if (!el) return { error: 'Nothing on the page matches ' + args.selector + '.' };
      if (isSecret(el)) return { error: 'password' };
      el.scrollIntoView({ block: 'center' });
      if (el.tagName === 'SELECT') {
        const want = args.text.trim().toLowerCase();
        const options = [...el.options];
        const option = options.find((o) => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want)
          || options.find((o) => o.text.toLowerCase().includes(want));
        if (!option) return { error: 'The list has no option “' + args.text + '”. It has: ' + options.slice(0, 30).map((o) => o.text.trim()).join(', ') };
        el.value = option.value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { typed: describe(el), value: option.text.trim() };
      }
      if (typeof el.focus === 'function') el.focus();
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
        if (el.readOnly || el.disabled) return { error: 'That field can’t be typed in.' };
        const value = args.clear ? args.text : el.value + args.text;
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: args.text }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      } else if (el.isContentEditable) {
        if (args.clear) { document.execCommand('selectAll', false, null); document.execCommand('delete', false, null); }
        document.execCommand('insertText', false, args.text);
      } else {
        return { error: 'That element isn’t a field: ' + el.tagName.toLowerCase() + '.' };
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
      return { typed: describe(el), submitted };
    }
    case 'scroll': {
      let target = null;
      if (args.selector) {
        target = find(args.selector);
        if (!target) return { error: 'Nothing on the page matches ' + args.selector + '.' };
        target.scrollBy({ top: args.dy, behavior: 'instant' });
        return { scrollTop: target.scrollTop, scrollHeight: target.scrollHeight, height: target.clientHeight };
      }
      window.scrollBy({ top: args.dy, behavior: 'instant' });
      const page = document.scrollingElement || document.documentElement;
      return { scrollTop: window.scrollY, scrollHeight: page.scrollHeight, height: window.innerHeight };
    }
    case 'state':
      return { title: document.title, url: location.href, readyState: document.readyState };
    default:
      return { error: 'Unknown operation.' };
    }
    """#
}
