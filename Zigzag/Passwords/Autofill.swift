import AppKit
import WebKit

/// Offers saved logins when a sign-in field is focused, and fills the one picked. Only logins saved for the
/// frame's exact origin (scheme, host and port) are offered, and the origin is checked again right before
/// filling, so a page that navigated away in between gets nothing. Filling needs no Touch ID; showing or copying
/// a password does.
@MainActor
final class Autofill: NSObject, WKScriptMessageHandler {
    static let shared = Autofill()
    static let messageName = "zigzagAutofill"

    private var menu: AutofillMenu?
    /// The frame and field the menu belongs to.
    private var target: (webView: BrowserWebView, frame: WKFrameInfo, origin: Origin)?
    /// Bumped on every focus change, so a slow vault lookup for an old field never shows a menu.
    private var generation = 0
    /// The new-password field's own rules, for the generator.
    private var rules = PasswordGenerator.Rules()

    /// Offer saved logins in sign-in fields. On by default, unless a password-manager extension is handling them.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "PasswordsAutofill") as? Bool ?? !PasswordManagers.isActive }
        set { UserDefaults.standard.set(newValue, forKey: "PasswordsAutofill") }
    }

    static var script: WKUserScript {
        WKUserScript(source: watcher, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let webView = message.webView as? BrowserWebView,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "focus":
            generation += 1
            // Fields inside frames are positioned relative to the frame, which the page can't tell us reliably.
            guard message.frameInfo.isMainFrame, Self.isOn,
                  let rect = body["rect"] as? [String: Double], let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] else { hide(); return }
            let security = message.frameInfo.securityOrigin
            let origin = Origin(scheme: security.protocol, host: security.host.lowercased(), port: security.port == 0 ? nil : security.port)
            // The page measures in CSS pixels; at a site's zoom, each is pageZoom points.
            let zoom = webView.pageZoom
            let field = NSRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
            let frame = message.frameInfo
            let current = generation
            if body["isNew"] as? Bool == true {
                guard !(webView.owner?.isPrivate ?? false) else { hide(); return }
                rules = PasswordGenerator.Rules(passwordRules: body["rules"] as? String ?? "", minLength: body["minLength"] as? Int ?? -1,
                                                maxLength: body["maxLength"] as? Int ?? -1)
                show([.generate], under: field, in: webView, frame: frame, origin: origin)
                return
            }
            Task {
                let logins = ((try? await PasswordStore.shared.all()) ?? []).filter { $0.origin.fills(on: origin) }
                    .sorted { ($0.lastUsed ?? $0.modified) > ($1.lastUsed ?? $1.modified) }
                guard current == self.generation, !logins.isEmpty else { if current == self.generation { self.hide() }; return }
                self.show(logins.map { .login($0) }, under: field, in: webView, frame: frame, origin: origin)
            }
        case "blur":
            generation += 1
            let current = generation
            // A click on the menu blurs the field first; let the click land before hiding. Focus that moved on to
            // another field meanwhile has its own menu, which stays.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, current == self.generation, let menu = self.menu, !menu.isPointerInside else { return }
                self.hide()
            }
        case "key":
            guard let menu, let key = body["key"] as? String else { return }
            switch key {
            case "ArrowDown": menu.move(1); markSelected(menu.selected != nil)
            case "ArrowUp": menu.move(-1); markSelected(menu.selected != nil)
            case "Enter": if let item = menu.selected { pick(item) }
            case "Escape": hide()
            default: break
            }
        default: break
        }
    }

    private func show(_ items: [AutofillMenu.Item], under field: NSRect, in webView: BrowserWebView, frame: WKFrameInfo, origin: Origin) {
        guard let overlay = WindowManager.shared.controllers.first(where: { $0.window === webView.window })?.root.overlay else { return }
        menu?.removeFromSuperview()
        let menu = AutofillMenu(items: Array(items.prefix(8)), origin: origin)
        menu.onPick = { [weak self] item in self?.pick(item) }
        let fieldInOverlay = overlay.convert(webView.convert(field, to: nil), from: nil)
        let width = min(max(fieldInOverlay.width, 260), 360)
        let height = menu.contentHeight
        var y = fieldInOverlay.maxY + Tokens.Space.x1
        if y + height > overlay.bounds.maxY - Tokens.Space.x2 { y = fieldInOverlay.minY - Tokens.Space.x1 - height }
        let x = min(max(fieldInOverlay.minX, Tokens.Space.x2), overlay.bounds.maxX - width - Tokens.Space.x2)
        menu.frame = NSRect(x: x, y: y, width: width, height: height)
        overlay.addSubview(menu)
        menu.present(always: true)
        self.menu = menu
        target = (webView, frame, origin)
        setSuggesting(true)
    }

    func hide() {
        guard let menu else { return }
        setSuggesting(false)
        self.menu = nil
        target = nil
        menu.dismiss(always: true)
    }

    /// While the menu is up, the page script hands arrow keys and Escape to it; Return only once a login in it is
    /// highlighted, so Return in a field still signs in as usual.
    private func setSuggesting(_ on: Bool) {
        guard let target else { return }
        target.webView.evaluateJavaScript("window.__zigzagSuggesting = \(on); window.__zigzagSelected = false", in: target.frame, in: .defaultClient)
    }

    private func markSelected(_ on: Bool) {
        guard let target else { return }
        target.webView.evaluateJavaScript("window.__zigzagSelected = \(on)", in: target.frame, in: .defaultClient)
    }

    private func pick(_ item: AutofillMenu.Item) {
        switch item {
        case .login(let login): fill(login)
        case .generate: fillGenerated()
        }
    }

    /// Fills a new strong password into the form's new-password fields, and saves it right away, so it's never
    /// lost if the sign-up's submit goes unnoticed. The username is added when the form is sent.
    private func fillGenerated() {
        guard let target else { return }
        let origin = target.origin
        let webView = target.webView
        hide()
        let candidates = PasswordGenerator.candidates(rules, count: 6)
        Task {
            let arguments: [String: Any] = ["candidates": candidates.map { $0.withUnsafeString { String($0) } }]
            let result = try? await webView.callAsyncJavaScript(Self.generatedFiller, arguments: arguments, in: target.frame, contentWorld: .defaultClient) as? [String: Any]
            let controller = WindowManager.shared.controllers.first { $0.window === webView.window }
            guard let index = result?["index"] as? Int, candidates.indices.contains(index) else {
                if let controller { Toast.show("This site’s password rules didn’t fit a strong password. Type one yourself.", symbol: "exclamationmark.triangle", duration: 4, in: controller) }
                return
            }
            let password = candidates[index]
            let username = result?["username"] as? String
            do {
                try await PasswordStore.shared.save(origin: origin, username: username ?? "", password: password)
                if let controller { Toast.show("Strong password saved for \(origin.displayName)", symbol: "key.fill", duration: 2, in: controller) }
            } catch {
                if let controller { Toast.show("Couldn’t save the new password. Copy it before you leave this page.", symbol: "exclamationmark.triangle", duration: 4, in: controller) }
            }
        }
    }

    private func fill(_ login: Credential) {
        guard let target else { return }
        hide()
        // The page may have moved on since the menu opened: it must still be the login's own site, in the tab
        // you're looking at. The page script checks again at the moment it fills.
        let controller = WindowManager.shared.controllers.first { $0.window === target.webView.window }
        guard login.origin.fills(on: target.origin), Origin(target.webView.url) == target.origin,
              controller?.selectedWebView === target.webView else { return }
        Task {
            guard let password = try? await PasswordStore.shared.password(for: login.id) else {
                if let controller = WindowManager.shared.controllers.first(where: { $0.window === target.webView.window }) {
                    Toast.show("Couldn’t open that password. Try again from the Passwords window.", symbol: "exclamationmark.triangle", duration: 3, in: controller)
                }
                return
            }
            // Passed as an argument, never pasted into the script's source, and held only for the call.
            let arguments: [String: Any] = ["username": login.username, "password": password.withUnsafeString { String($0) },
                                            "expectedOrigin": target.origin.description]
            let filled = try? await target.webView.callAsyncJavaScript(Self.filler, arguments: arguments, in: target.frame, contentWorld: .defaultClient)
            // Private windows leave no trace, not even "last used".
            if (filled as? Bool) != false, !(target.webView.owner?.isPrivate ?? false) { try? await PasswordStore.shared.markUsed(login.id) }
        }
    }

    /// Reports focus on sign-in fields (with the field's place on screen), blur, and the keys the menu takes.
    private static let watcher = """
    (() => {
      if (window.__zigzagAutofillWatcher) return;
      window.__zigzagAutofillWatcher = true;
      const post = (m) => { try { window.webkit.messageHandlers.zigzagAutofill.postMessage(m); } catch (e) {} };
      const signIn = (el) => {
        if (!el || el.tagName !== 'INPUT' || el.disabled || el.readOnly) return false;
        if (el.type === 'password') return !/new-password/.test(el.autocomplete || '');
        if (!['text', 'email', 'tel', ''].includes(el.type)) return false;
        if (/username|email/.test(el.autocomplete || '')) return true;
        const scope = el.form || document;
        return !!scope.querySelector('input[type=password]') && /user|login|email|account|id|name/i.test((el.name || '') + (el.id || '') + (el.placeholder || '') + (el.getAttribute('aria-label') || ''));
      };
      // A field for a new password: marked new-password, or on a form with several password fields (sign-up and
      // confirm, or current, new and confirm) where it isn't the current one.
      const isNew = (el) => {
        if (!el || el.tagName !== 'INPUT' || el.type !== 'password' || el.disabled || el.readOnly) return false;
        if (/new-password/.test(el.autocomplete || '')) return true;
        if (/current-password/.test(el.autocomplete || '')) return false;
        const all = [...(el.form || document).querySelectorAll('input[type=password]')].filter((f) => f.getBoundingClientRect().width > 1);
        if (all.length < 2) return false;
        if (all.some((f) => /current-password/.test(f.autocomplete || ''))) return true;  // and this isn't it
        if (all.length === 2) return true;  // a password and its confirmation
        return all.indexOf(el) > 0;         // current, new, confirm
      };
      const report = (el) => {
        const r = el.getBoundingClientRect();
        post({ kind: 'focus', isNew: isNew(el) && !el.value, rules: el.getAttribute('passwordrules') || '',
               minLength: el.minLength, maxLength: el.maxLength, rect: { x: r.left, y: r.top, w: r.width, h: r.height } });
      };
      const wanted = (el) => signIn(el) || isNew(el);
      document.addEventListener('focusin', (e) => { if (!window.__zigzagFilling && wanted(e.target)) report(e.target); }, true);
      document.addEventListener('mousedown', (e) => { if (e.isTrusted && e.target === document.activeElement && wanted(e.target)) report(e.target); }, true);
      document.addEventListener('focusout', (e) => { if (wanted(e.target)) post({ kind: 'blur' }); }, true);
      document.addEventListener('input', (e) => { if (window.__zigzagSuggesting && wanted(e.target)) post({ kind: 'blur' }); }, true);
      window.addEventListener('scroll', () => { if (window.__zigzagSuggesting) post({ kind: 'blur' }); }, true);
      document.addEventListener('keydown', (e) => {
        // Only keys a person pressed: a page can send itself key events, but must never pick a login with them.
        if (!e.isTrusted || !window.__zigzagSuggesting || !['ArrowDown', 'ArrowUp', 'Enter', 'Escape'].includes(e.key)) return;
        if (e.key === 'Enter' && !window.__zigzagSelected) return;
        e.preventDefault(); e.stopPropagation();
        post({ kind: 'key', key: e.key });
      }, true);
    })();
    """

    /// Picks the first candidate the field accepts (its `pattern` and lengths), puts it in every new-password
    /// field of the focused form (the password and its confirmation), and returns its index and the username
    /// typed so far, if any.
    private static let generatedFiller = """
    const active = document.activeElement;
    const scope = (active && active.form) || document;
    // Only fields a person can see: a real size, on the page, not transparent or hidden by an ancestor.
    const visible = (el) => {
      if (el.disabled || el.readOnly || el.type === 'hidden') return false;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8 || r.right < 0 || r.bottom < 0 || r.left > innerWidth + 1000) return false;
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
      const style = getComputedStyle(el);
      return style.visibility === 'visible' && parseFloat(style.opacity) >= 0.1;
    };
    const inputs = [...scope.querySelectorAll('input')].filter(visible);
    const passwords = inputs.filter((el) => el.type === 'password');
    const current = passwords.find((el) => /current-password/.test(el.autocomplete || ''));
    const fresh = passwords.filter((el) => el !== current && (/new-password/.test(el.autocomplete || '') || !/current-password/.test(el.autocomplete || '')));
    const targets = current || passwords.length < 3 ? fresh : fresh.slice(1);
    const field = targets.includes(active) ? active : targets[0];
    if (!field) return { index: -1 };
    const fits = (value) => {
      if (field.minLength > 0 && value.length < field.minLength) return false;
      if (field.maxLength > 0 && value.length > field.maxLength) return false;
      if (!field.pattern) return true;
      try { return new RegExp('^(?:' + field.pattern + ')$', 'v').test(value); } catch (e) {
        try { return new RegExp('^(?:' + field.pattern + ')$', 'u').test(value); } catch (e2) { return true; }
      }
    };
    const index = candidates.findIndex(fits);
    if (index < 0) return { index: -1 };
    const password = candidates[index];
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    for (const el of targets) {
      setter.call(el, password);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    const first = passwords[0];
    const users = inputs.filter((el) => ['text', 'email', 'tel', ''].includes(el.type) && el.value && inputs.indexOf(el) < inputs.indexOf(first));
    const marked = users.find((el) => /username|email/.test(el.autocomplete || '') || el.type === 'email');
    return { index, username: (marked || users[users.length - 1] || {}).value || '' };
    """

    /// Fills the focused form: the username field (if there is one) and the password field, the way typing would.
    private static let filler = """
    // Checked here, at the moment of filling: only the exact site the login belongs to gets it.
    if (location.origin !== expectedOrigin) return false;
    const active = document.activeElement;
    const scope = (active && active.form) || document;
    // Only fields a person can see: a real size, on the page, not transparent or hidden by an ancestor.
    const visible = (el) => {
      if (el.disabled || el.readOnly || el.type === 'hidden') return false;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8 || r.right < 0 || r.bottom < 0 || r.left > innerWidth + 1000) return false;
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
      const style = getComputedStyle(el);
      return style.visibility === 'visible' && parseFloat(style.opacity) >= 0.1;
    };
    const inputs = [...scope.querySelectorAll('input')].filter(visible);
    const passwordField = inputs.find((el) => el.type === 'password' && !/new-password/.test(el.autocomplete || ''));
    const userFields = inputs.filter((el) => ['text', 'email', 'tel', ''].includes(el.type));
    const userField = userFields.find((el) => /username|email/.test(el.autocomplete || ''))
      || (passwordField ? userFields.filter((el) => inputs.indexOf(el) < inputs.indexOf(passwordField)).pop() : null)
      || (active && userFields.includes(active) ? active : null);
    const set = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      el.focus();
      setter.call(el, value);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    // Focusing the fields to fill them mustn't bring the menu back.
    window.__zigzagFilling = true;
    try {
      if (userField && username) set(userField, username);
      if (passwordField) set(passwordField, password);
    } finally {
      setTimeout(() => { window.__zigzagFilling = false; }, 0);
    }
    """
}

/// The list under a sign-in field: one row per saved login, newest used first, or a strong new password.
final class AutofillMenu: FloatingPanelView {
    enum Item {
        case login(Credential)
        case generate
    }

    private var rows: [AutofillRow] = []
    private let footer = TextButton(title: "Passwords", font: Tokens.Font.small(.medium))
    private let footerLine = ColorView(color: Tokens.Color.separator)
    private let hasFooter: Bool
    private var selection = -1 { didSet { rows.enumerated().forEach { $0.element.isSelected = $0.offset == selection } } }
    var onPick: ((Item) -> Void)?

    private let pad = Tokens.Space.x1 + 2
    private let rowHeight = Tokens.Space.x10 + Tokens.Space.x1

    init(items: [Item], origin: Origin) {
        hasFooter = items.contains { if case .login = $0 { true } else { false } }
        super.init(frame: .zero)
        if hasFooter {
            [footerLine, footer].forEach { addSubview($0) }
            footer.onClick = { _ in
                Autofill.shared.hide()
                PasswordsWindowController.show()
            }
        }
        radius = Tokens.Radius.panel
        rows = items.map { item in
            let row = AutofillRow(item: item, origin: origin)
            row.onClick = { [weak self] _ in self?.onPick?(item) }
            addSubview(row)
            return row
        }
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Passwords")
        onLayout = { [weak self] in self?.layoutRows() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private let footerHeight = Tokens.Space.x8

    var contentHeight: CGFloat { pad * 2 + CGFloat(rows.count) * rowHeight + (hasFooter ? footerHeight + pad : 0) }

    var selected: Item? { rows.indices.contains(selection) ? rows[selection].item : (rows.count == 1 ? rows[0].item : nil) }

    var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = selection < 0 ? (delta > 0 ? 0 : rows.count - 1) : (selection + delta + rows.count) % rows.count
    }

    private func layoutRows() {
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: pad, y: pad + CGFloat(index) * rowHeight, width: bounds.width - pad * 2, height: rowHeight)
        }
        guard hasFooter else { return }
        let y = pad + CGFloat(rows.count) * rowHeight + pad / 2
        footerLine.frame = NSRect(x: pad + Tokens.Space.x2, y: y, width: bounds.width - (pad + Tokens.Space.x2) * 2, height: Tokens.Metric.hairline)
        footer.frame = NSRect(x: pad, y: y + pad / 2, width: footer.fittingWidth, height: footerHeight)
    }
}

private final class AutofillRow: InteractiveView {
    let item: AutofillMenu.Item
    private let icon = NSImageView()
    private let name: Label
    private let detail: Label

    init(item: AutofillMenu.Item, origin: Origin) {
        self.item = item
        switch item {
        case .login(let login):
            name = Label(login.username.isEmpty ? "No username" : login.username, font: Tokens.Font.body(.medium),
                         color: login.username.isEmpty ? Tokens.Color.textSecondary : Tokens.Color.textPrimary)
            detail = Label("Password for \(login.origin.displayName)", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = origin.url.flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? Tokens.Symbol.image("key.fill")
            icon.contentTintColor = Tokens.Color.textSecondary
        case .generate:
            name = Label("Use Strong Password", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
            detail = Label("Saved to your Keychain for \(origin.displayName)", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = Tokens.Symbol.image("key.viewfinder")
            icon.contentTintColor = Tokens.Color.accent
        }
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.control + 2
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        [icon, name, detail].forEach { addSubview($0) }
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(name.stringValue)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x4
        icon.frame = NSRect(x: Tokens.Space.x2 + 2, y: (bounds.height - side) / 2, width: side, height: side)
        let x = icon.frame.maxX + Tokens.Space.x3
        let total = name.lineHeight + detail.lineHeight
        let top = (bounds.height - total) / 2
        name.frame = NSRect(x: x, y: top, width: bounds.width - x - Tokens.Space.x2, height: name.lineHeight)
        detail.frame = NSRect(x: x, y: name.frame.maxY, width: bounds.width - x - Tokens.Space.x2, height: detail.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : (isHovered || isSelected) ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}
