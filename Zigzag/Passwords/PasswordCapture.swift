import AppKit
import WebKit

/// Notices logins as they happen and offers to save them once the site has taken them. The watching script runs in
/// Zigzag's own script world, where neither the page nor extensions can see it; the password goes from its message
/// straight into a `SecretString`, and nothing about it is logged.
///
/// A login is held, per tab, from the moment it's sent until the site answers: offered once the tab is on a page
/// without the sign-in form (or on another site), dropped if the form comes back with its password empty. A
/// mistyped password is never offered, so it can't replace a good saved one.
@MainActor
final class PasswordCapture: NSObject, WKScriptMessageHandler {
    static let shared = PasswordCapture()
    static let messageName = "zigzagPassword"

    /// Offer to save passwords. On by default, unless a password-manager extension is handling them.
    static var offersToSave: Bool {
        get { UserDefaults.standard.object(forKey: "PasswordsOfferToSave") as? Bool ?? !PasswordManagers.isActive }
        set { UserDefaults.standard.set(newValue, forKey: "PasswordsOfferToSave") }
    }

    /// For logins split over two pages: the username from the first step, per tab, for a couple of minutes.
    private var pendingUsernames: [ObjectIdentifier: (origin: Origin, username: String, at: Date)] = [:]

    /// A login that was sent, waiting for the site's answer.
    private final class HeldLogin {
        let origin: Origin
        let username: String
        let password: SecretString
        let isChange: Bool
        weak var tab: Tab?
        /// Sent from a frame of another site (an embedded sign-in): the page the tab was on then. The tab's own page
        /// says nothing about how the frame's sign-in went, so only the tab moving on counts as it having worked.
        let framedOn: URL?
        var urlToken: SignalToken?
        var checks: [DispatchWorkItem] = []

        init(origin: Origin, username: String, password: SecretString, isChange: Bool, tab: Tab, framedOn: URL?) {
            self.origin = origin
            self.username = username
            self.password = password
            self.isChange = isChange
            self.tab = tab
            self.framedOn = framedOn
        }
    }

    /// Per tab: the login sent there whose answer hasn't come yet.
    private var held: [ObjectIdentifier: HeldLogin] = [:]

    /// What the page in a tab shows after a login was sent.
    nonisolated struct PageAfterLogin: Equatable, Sendable {
        /// The host of the page now.
        var host: String?
        /// A password field a person can see.
        var hasPasswordField: Bool
        /// …with something in it.
        var passwordFilled: Bool
    }

    nonisolated enum Verdict: Equatable, Sendable {
        /// The site took it: offer to save or update.
        case offer
        /// The sign-in failed: forget it, offering nothing.
        case drop
        /// Can't tell yet (still on the form, the password still in it).
        case wait
    }

    /// Whether a login sent on `loginHost` worked, from the page the tab is on now. Another site means it went
    /// through (signed in, on to the app); on the same site, the form gone means it worked, the form back with its
    /// password empty means it didn't, and the password still typed in means the site hasn't answered.
    nonisolated static func verdict(loginHost: String, page: PageAfterLogin) -> Verdict {
        if let host = page.host?.lowercased(), !host.isEmpty, site(of: host) != site(of: loginHost.lowercased()) { return .offer }
        if !page.hasPasswordField { return .offer }
        return page.passwordFilled ? .wait : .drop
    }

    /// The site a host belongs to: a sign-in often hops between its hosts (accounts. to www.).
    nonisolated private static func site(of host: String) -> String { PublicSuffix.registrableDomain(host) ?? host }

    /// How long a sent login waits for the site's answer before it's forgotten.
    private static let holdFor: TimeInterval = 180

    static var script: WKUserScript {
        WKUserScript(source: watcher, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let webView = message.webView as? BrowserWebView, let tab = webView.owner,
              !tab.isPrivate, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let security = message.frameInfo.securityOrigin
        let origin = Origin(scheme: security.protocol, host: security.host.lowercased(), port: security.port == 0 ? nil : security.port)
        guard origin.scheme == "https" || origin.scheme == "http" else { return }
        let key = ObjectIdentifier(tab)
        let typedUsername = (body["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // A new page finished loading in the tab: the site's answer to a login sent before it, if one is waiting.
        if kind == "page" {
            guard message.frameInfo.isMainFrame, held[key] != nil else { return }
            judge(key, page: PageAfterLogin(host: origin.host, hasPasswordField: body["form"] as? Bool ?? false,
                                            passwordFilled: body["filled"] as? Bool ?? false))
            return
        }
        if kind == "username" {
            if !typedUsername.isEmpty { pendingUsernames[key] = (origin, typedUsername, Date()) }
            return
        }
        guard kind == "login" || kind == "change", let raw = body["password"] as? String, !raw.isEmpty else { return }
        let password = SecretString(raw)
        var username = typedUsername
        if username.isEmpty, let pending = pendingUsernames[key], pending.origin == origin, Date().timeIntervalSince(pending.at) < 120 {
            username = pending.username
        }
        pendingUsernames[key] = nil
        guard Self.offersToSave else { return }
        let framed = !message.frameInfo.isMainFrame && tab.url?.host()?.lowercased() != origin.host
        hold(HeldLogin(origin: origin, username: username, password: password, isChange: kind == "change", tab: tab,
                       framedOn: framed ? tab.url : nil), key: key)
    }

    /// Keeps a sent login until the site answers. The answer is usually a new page, which reports itself; a site that
    /// signs in without one (it changes its address, or just takes the form away) is checked on now and then.
    private func hold(_ login: HeldLogin, key: ObjectIdentifier) {
        release(key)
        held[key] = login
        login.urlToken = login.tab?.changed.observe { [weak self] change in
            guard change == .url else { return }
            self?.check(key, after: 0.8)
        }
        for delay in [3.0, 8.0, 20.0] { check(key, after: delay) }
        let expire = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.held[key] === login { self?.release(key) } }
        }
        login.checks.append(expire)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdFor, execute: expire)
    }

    private func release(_ key: ObjectIdentifier) {
        guard let login = held.removeValue(forKey: key) else { return }
        login.urlToken = nil
        login.checks.forEach { $0.cancel() }
    }

    /// Asks the tab's page how it looks now. Not while a new page is on its way: that one reports itself once it's
    /// loaded, and a half-built page could look like the form had gone.
    private func check(_ key: ObjectIdentifier, after delay: TimeInterval) {
        guard let login = held[key] else { return }
        let work = DispatchWorkItem { [weak self, weak login] in
            MainActor.assumeIsolated {
                guard let self, let login, self.held[key] === login, let tab = login.tab, !tab.isClosed,
                      let webView = tab.webView, !webView.isLoading else { return }
                // Only whether there's a password field and whether it's filled; never what's in it.
                webView.evaluateJavaScript(Self.stateCall, in: nil, in: .defaultClient) { [weak self, weak login, weak tab] result in
                    guard let self, let login, self.held[key] === login, let tab,
                          case .success(let value) = result, let state = value as? [String: Any] else { return }
                    self.judge(key, page: PageAfterLogin(host: tab.url?.host(), hasPasswordField: state["form"] as? Bool ?? false,
                                                         passwordFilled: state["filled"] as? Bool ?? false))
                }
            }
        }
        login.checks.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func judge(_ key: ObjectIdentifier, page: PageAfterLogin) {
        guard let login = held[key] else { return }
        if let framedOn = login.framedOn {
            // Still on the page that held the frame: wait, and if the tab never moves on, nothing is offered.
            guard let now = login.tab?.url, now != framedOn else { return }
            judge(key, verdict: .offer)
            return
        }
        judge(key, verdict: Self.verdict(loginHost: login.origin.host, page: page))
    }

    private func judge(_ key: ObjectIdentifier, verdict: Verdict) {
        guard let login = held[key] else { return }
        switch verdict {
        case .wait:
            return
        case .drop:
            release(key)
        case .offer:
            release(key)
            guard let tab = login.tab, !tab.isClosed, Self.offersToSave else { return }
            Task { await self.consider(origin: login.origin, username: login.username, password: login.password, isChange: login.isChange, in: tab) }
        }
    }

    /// The watcher's own look at the page, from Zigzag's script world.
    private static let stateCall = "window.__zigzagPasswordState ? window.__zigzagPasswordState() : null"

    /// Saves nothing by itself: decides whether to ask, and what.
    private func consider(origin: Origin, username: String, password: SecretString, isChange: Bool, in tab: Tab) async {
        let store = PasswordStore.shared
        guard await !store.neverSaves(on: origin) else { return }
        let saved = (try? await store.credentials(for: origin)) ?? []
        // A strong password filled here was saved without a username; the sign-up form now supplies it.
        if !username.isEmpty, let generated = saved.first(where: { $0.username.isEmpty }),
           let stored = try? await store.password(for: generated.id), stored.matches(password) {
            var named = generated
            named.username = username
            try? await store.update(named)
            return
        }
        // A change form often has no username; if there's one login for the site, it's that one.
        // Email addresses are the same login whatever their capitals ("Sam@x.com" is "sam@x.com").
        let target = saved.first { $0.username.caseInsensitiveCompare(username) == .orderedSame }
            ?? (isChange && username.isEmpty && saved.count == 1 ? saved.first : nil)
        if let target {
            if let current = try? await store.password(for: target.id), current.matches(password) {
                try? await store.markUsed(target.id)
                return
            }
            SavePasswordPrompt.show(.update(target), origin: origin, password: password, in: tab)
        } else {
            SavePasswordPrompt.show(.save(username: username), origin: origin, password: password, in: tab)
        }
    }

    /// Watches password fields and reports a login when it's submitted, or when the page goes away with a
    /// typed password (sites that sign in without a form). Hidden fields are ignored. The top page also says, once
    /// it has loaded, whether it shows a password field and whether it's filled: how a sent login turned out.
    private static let watcher = """
    (() => {
      if (window.__zigzagPasswordWatcher) return;
      window.__zigzagPasswordWatcher = true;
      const post = (message) => { try { window.webkit.messageHandlers.zigzagPassword.postMessage(message); } catch (e) {} };
      // Only fields a person can see: a real size, on the page, not transparent or hidden by an ancestor.
      const visible = (el) => {
        if (!el || el.type === 'hidden' || el.disabled) return false;
        const r = el.getBoundingClientRect();
        if (r.width < 8 || r.height < 8 || r.right < 0 || r.bottom < 0 || r.left > innerWidth + 1000) return false;
        if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
        const s = getComputedStyle(el);
        return s.visibility === 'visible' && parseFloat(s.opacity) >= 0.1;
      };
      const fields = (scope) => [...(scope || document).querySelectorAll('input')].filter(visible);
      const isUserField = (el) => /username|email/.test(el.autocomplete || '') || el.type === 'email'
        || ((el.type === 'text' || el.type === 'tel' || el.type === '') && /user|login|email|account|id/i.test((el.name || '') + (el.id || '') + (el.placeholder || '')));
      const usernameBefore = (password, scope) => {
        const all = fields(scope);
        const marked = all.find((el) => /username/.test(el.autocomplete || '') && el.value);
        if (marked) return marked.value;
        const before = all.slice(0, all.indexOf(password)).filter((el) => el.type !== 'password' && el.value && (isUserField(el) || el.type === 'text'));
        return before.length ? before[before.length - 1].value : '';
      };
      let typed = new WeakSet(), last = '', pressed = -Infinity;
      // A password typed again (after a failed try, often the same length) is a new login to report. Only typing a
      // person did counts: a page can fill in a password of its own, but mustn't get it offered for saving.
      document.addEventListener('input', (e) => { if (e.isTrusted && e.target && e.target.type === 'password') { typed.add(e.target); last = ''; } }, true);
      // Typed here, or filled from Zigzag's own menu (which marks the fields it fills).
      const yours = (el) => typed.has(el) || !!(window.__zigzagFilled && window.__zigzagFilled.has(el));
      // A form sent just after a click or key press of yours, not one the page sends by itself.
      for (const kind of ['mousedown', 'keydown']) document.addEventListener(kind, (e) => { if (e.isTrusted) pressed = performance.now(); }, true);
      const capture = (scope) => {
        const passwords = fields(scope).filter((el) => el.type === 'password' && el.value);
        if (!passwords.length) {
          // The first page of a two-step login: just the username.
          const user = fields(scope).find((el) => isUserField(el) && el.value);
          if (user && !fields(scope).some((el) => el.type === 'password')) post({ kind: 'username', username: user.value });
          return;
        }
        const fresh = passwords.filter((el) => /new-password/.test(el.autocomplete || ''));
        const change = fresh.length > 0 || passwords.length >= 2;
        const chosen = change ? (fresh.length ? fresh[fresh.length - 1] : passwords[passwords.length - 1]) : passwords[0];
        if (!yours(chosen)) return;
        const signature = chosen.value.length + ':' + location.href;
        if (signature === last) return;
        last = signature;
        post({ kind: change ? 'change' : 'login', username: usernameBefore(passwords[0], scope), password: chosen.value });
      };
      document.addEventListener('submit', (e) => { if (e.isTrusted && performance.now() - pressed < 1000) capture(e.target); }, true);
      // A button that sends the form, not one that shows the password or links to "Forgot?": a submit button, or
      // one labelled like signing in.
      const label = (el) => ((el.getAttribute('aria-label') || '') + ' ' + (el.value || '') + ' ' + (el.textContent || '')).trim();
      const sends = (button) => {
        const text = label(button);
        if (/show|hide|reveal|forgot|reset|visib|显示|隐藏|忘记/i.test(text)) return false;
        if (button.matches('input[type=submit], button[type=submit]') || (button.tagName === 'BUTTON' && !button.getAttribute('type') && button.form)) return true;
        return /log ?in|sign ?in|sign ?up|log ?on|continue|next|submit|register|create|save|update|change|登录|登入|注册|继续|下一步|确定|提交/i.test(text);
      };
      document.addEventListener('click', (e) => {
        if (!e.isTrusted) return;
        const button = e.target && e.target.closest ? e.target.closest('button, input[type=submit], [role=button]') : null;
        if (button && sends(button)) capture(button.form || button.closest('form') || document);
      }, true);
      // Return in the password field, or in the username on its own page of a two-step sign-in.
      document.addEventListener('keydown', (e) => {
        if (!e.isTrusted || e.key !== 'Enter' || e.isComposing || !e.target || e.target.tagName !== 'INPUT') return;
        if (e.target.type === 'password' || isUserField(e.target)) capture(e.target.form || document);
      }, true);
      window.addEventListener('pagehide', () => {
        if (fields(document).some((el) => el.type === 'password' && el.value && typed.has(el))) capture(document);
      });
      // Whether the page shows a password field, and whether anything's in it. Never the password itself.
      const state = () => {
        const passwords = fields(document).filter((el) => el.type === 'password');
        return { form: passwords.length > 0, filled: passwords.some((el) => !!el.value) };
      };
      window.__zigzagPasswordState = state;
      if (window === top) {
        // Once the page has loaded and drawn its form (if it has one), or after a few seconds for pages that never
        // quite finish.
        let reported = false;
        const report = () => {
          if (reported) return;
          reported = true;
          setTimeout(() => post(Object.assign({ kind: 'page' }, state())), 400);
        };
        if (document.readyState === 'complete') report();
        else { addEventListener('load', report, { once: true }); setTimeout(report, 3000); }
      }
    })();
    """
}

/// Password-manager extensions. When one is installed and on, it handles passwords and Zigzag stays out of the way.
enum PasswordManagers {
    static let extensionIDs: Set<String> = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa",  // 1Password
        "nngceckbapebfimnlniiiahkandclblb",  // Bitwarden
        "hdokiejnpimakedhajhdlcegeplioahd",  // LastPass
        "fdjamakpfbbddfjaooikfcpapjohcfmg",  // Dashlane
        "ghmbeldphafepmbegfdlkpapadhbakde",  // Proton Pass
        "bfogiafebfohielmmehodmfbbebbbpei",  // Keeper
        "eiaeiblijfjekdanodkjadfinkhbfgcd",  // NordPass
        "pejdijmoenmkgeppbflobdenhhabjlaj",  // iCloud Passwords
    ]

    static var isActive: Bool { active != nil }

    /// The installed, turned-on password manager's name.
    static var active: String? {
        guard #available(macOS 15.4, *) else { return nil }
        // "1Password – Password Manager" reads as "1Password".
        let name = ExtensionHost.shared.contexts.first { extensionIDs.contains($0.uniqueIdentifier) }?.webExtension.displayName
        return name.map { full in
            let cut = [" –", " -", ":"].compactMap { full.range(of: $0)?.lowerBound }.min() ?? full.endIndex
            return String(full[..<cut]).trimmingCharacters(in: .whitespaces)
        }
    }
}
