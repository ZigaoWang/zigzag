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

    /// Offer to save passwords, chosen for each profile. On by default, unless a password-manager extension is
    /// handling them there.
    static func offersToSave(in profile: Profile) -> Bool {
        PasswordManagers.zigzagHandles(chosen: ProfileKey.offersToSavePasswords.choice(in: profile.id), managerOn: PasswordManagers.active(in: profile) != nil)
    }

    static func setOffersToSave(_ on: Bool, in profile: Profile) {
        UserDefaults.standard.set(on, forKey: ProfileKey.offersToSavePasswords.name(in: profile.id))
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

    /// A strong password filled from Use Strong Password, kept as a pending login (`Credential.isPendingGenerated`)
    /// until the site takes it. One per site: making another for the same form replaces it.
    private final class PendingGenerated {
        let origin: Origin
        let id: UUID
        let password: SecretString
        let username: String
        weak var tab: Tab?
        /// The last press that may have sent its form (a button, or Return in one of its fields).
        var attempted: Date?
        var urlToken: SignalToken?
        var checks: [DispatchWorkItem] = []

        init(origin: Origin, id: UUID, password: SecretString, username: String, tab: Tab?) {
            self.origin = origin
            self.id = id
            self.password = password
            self.username = username
            self.tab = tab
        }

        func stopWatching() {
            urlToken = nil
            checks.forEach { $0.cancel() }
            checks = []
        }
    }

    private var generated: [Origin: PendingGenerated] = [:]

    /// How long a filled strong password is watched for its form going through.
    private static let watchGeneratedFor: TimeInterval = 30 * 60
    /// How long after a press that may have sent the form a new page, or a new address, counts as its answer.
    nonisolated static let attemptCountsFor: TimeInterval = 45

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
            guard message.frameInfo.isMainFrame else { return }
            let page = PageAfterLogin(host: origin.host, hasPasswordField: body["form"] as? Bool ?? false, passwordFilled: body["filled"] as? Bool ?? false)
            if held[key] != nil { judge(key, page: page) }
            pageChanged(in: tab, page: page)
            return
        }
        // A press that may have sent the form a strong password was filled into.
        if kind == "attempt" {
            if message.frameInfo.isMainFrame, let pending = generated[origin], pending.tab === tab { pending.attempted = Date() }
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
        // A strong password Zigzag filled is settled whatever Offer to save says: choosing it was saying to keep it.
        let isGenerated = generated[origin]?.password.matches(password) ?? false
        guard Self.watches(offersToSave: Self.offersToSave(in: tab.profile), isGenerated: isGenerated) else { return }
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
            guard let tab = login.tab, !tab.isClosed else { return }
            let offers = Self.offersToSave(in: tab.profile)
            let pending = generated[login.origin].flatMap { $0.password.matches(login.password) ? $0 : nil }
            guard Self.watches(offersToSave: offers, isGenerated: pending != nil) else { return }
            if let pending { forgetGenerated(pending) }
            // The form's username, or else the one the strong password was made for.
            let username = login.username.isEmpty ? (pending?.username ?? "") : login.username
            Task { await self.consider(origin: login.origin, username: username, password: login.password, isChange: login.isChange, offers: offers, in: tab) }
        }
    }

    /// Whether a sent login is watched for the site's answer: always for a strong password Zigzag filled, which is
    /// settled whatever Offer to save says; otherwise only when Zigzag offers to save.
    nonisolated static func watches(offersToSave: Bool, isGenerated: Bool) -> Bool { offersToSave || isGenerated }

    /// Whether a strong password whose form was never seen sent (a page that sends it by script) is settled by the
    /// page the tab is on now: only soon after a press that may have sent it, and only once the site has taken it,
    /// the way `verdict` reads a sent login. A link followed, or an address typed, with no such press settles
    /// nothing, so a password the site never got never takes the account's place.
    nonisolated static func settlesGenerated(attempted: Date?, now: Date, loginHost: String, page: PageAfterLogin) -> Bool {
        guard let attempted else { return false }
        let since = now.timeIntervalSince(attempted)
        guard since >= 0, since < attemptCountsFor else { return false }
        return verdict(loginHost: loginHost, page: page) == .offer
    }

    // MARK: Strong passwords

    /// Keeps a strong password just filled into a page as a pending login of its own (never over the account's), and
    /// watches the tab for its form going through. Filling another for the same site before the first could have
    /// been sent replaces it, so trying a few leaves one behind, not several.
    @discardableResult
    func filledGenerated(_ password: SecretString, origin: Origin, username: String, in tab: Tab?) async throws -> Credential {
        let previous = generated[origin]
        // One that may have been sent stays: the site may have taken it.
        let replacing = previous.flatMap { $0.attempted == nil ? $0.id : nil }
        let credential = try await Self.keepGenerated(password, origin: origin, username: username, replacing: replacing, in: PasswordStore.shared)
        if let current = generated[origin] { forgetGenerated(current) }
        let pending = PendingGenerated(origin: origin, id: credential.id, password: password, username: username, tab: tab)
        generated[origin] = pending
        watch(pending)
        return credential
    }

    /// Saves a strong password as a pending login: over the pending one `replacing` names when it's still there and
    /// still pending on this site, otherwise as a new one.
    static func keepGenerated(_ password: SecretString, origin: Origin, username: String, replacing: UUID?,
                              in store: PasswordStore) async throws -> Credential {
        if let replacing, var earlier = try await store.credentials(for: origin).first(where: { $0.id == replacing && $0.isPendingGenerated }) {
            earlier.generatedFor = username
            earlier.modified = Date()
            try await store.update(earlier, password: password)
            return earlier
        }
        return try await store.saveGenerated(origin: origin, for: username, password: password)
    }

    private func watch(_ pending: PendingGenerated) {
        pending.urlToken = pending.tab?.changed.observe { [weak self, weak pending] change in
            guard change == .url, let pending else { return }
            self?.checkGenerated(pending, after: 0.8)
        }
        let expire = DispatchWorkItem { [weak self, weak pending] in
            MainActor.assumeIsolated { if let pending { self?.forgetGenerated(pending) } }
        }
        pending.checks.append(expire)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchGeneratedFor, execute: expire)
    }

    /// Stops watching for its form. The pending login stays in the vault, listed as a generated password.
    private func forgetGenerated(_ pending: PendingGenerated) {
        pending.stopWatching()
        if generated[pending.origin] === pending { generated[pending.origin] = nil }
    }

    /// A new page finished loading in a tab: the answer to a strong password's form sent from it, if there is one.
    private func pageChanged(in tab: Tab, page: PageAfterLogin) {
        for pending in generated.values where pending.tab === tab { settleIfTaken(pending, page: page) }
    }

    /// The tab's address changed without a new page (a single-page app): how its page looks a moment later.
    private func checkGenerated(_ pending: PendingGenerated, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self, weak pending] in
            MainActor.assumeIsolated {
                guard let self, let pending, self.generated[pending.origin] === pending, pending.attempted != nil, let tab = pending.tab,
                      !tab.isClosed, let webView = tab.webView, !webView.isLoading else { return }
                // Only whether there's a password field and whether it's filled; never what's in it.
                webView.evaluateJavaScript(Self.stateCall, in: nil, in: .defaultClient) { [weak self, weak pending, weak tab] result in
                    guard let self, let pending, let tab, case .success(let value) = result, let state = value as? [String: Any] else { return }
                    self.settleIfTaken(pending, page: PageAfterLogin(host: tab.url?.host(), hasPasswordField: state["form"] as? Bool ?? false,
                                                                     passwordFilled: state["filled"] as? Bool ?? false))
                }
            }
        }
        pending.checks.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func settleIfTaken(_ pending: PendingGenerated, page: PageAfterLogin) {
        guard generated[pending.origin] === pending,
              Self.settlesGenerated(attempted: pending.attempted, now: Date(), loginHost: pending.origin.host, page: page) else { return }
        forgetGenerated(pending)
        Task { _ = await Self.settleGenerated(origin: pending.origin, username: pending.username, password: pending.password, in: PasswordStore.shared) }
    }

    /// The watcher's own look at the page, from Zigzag's script world.
    private static let stateCall = "window.__zigzagPasswordState ? window.__zigzagPasswordState() : null"

    /// A strong password from "Use Strong Password" is kept as a pending login of its own the moment it's filled
    /// (`filledGenerated`), never over the one saved for the account, so a change the site turns down, or a reload
    /// before the form is sent, loses nothing. Once the site has taken the form it settles: the account's saved login
    /// (`username`'s, or else the one the form had when it was filled) takes the new password and the pending one
    /// goes, or, for a new account, the pending one becomes its login. With no username to go by it stays pending,
    /// unless it's the site's only login. True when `password` was one.
    static func settleGenerated(origin: Origin, username: String, password: SecretString, in store: PasswordStore) async -> Bool {
        let saved = (try? await store.credentials(for: origin)) ?? []
        guard let generated = await pendingGenerated(matching: password, among: saved, in: store) else { return false }
        let name = username.isEmpty ? generated.generatedFor : username
        let accounts = saved.filter { $0.id != generated.id && !$0.isPendingGenerated }
        // Email addresses are the same login whatever their capitals ("Sam@x.com" is "sam@x.com").
        if !name.isEmpty, var account = accounts.first(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame }) {
            account.modified = Date()
            do {
                try await store.update(account, password: password)
                try? await store.markUsed(account.id)
                try? await store.delete(generated.id)
            } catch {
                // Not updated: the pending one keeps the new password, so it isn't lost.
            }
        } else if !name.isEmpty || accounts.isEmpty {
            var named = generated
            named.username = name
            named.isPendingGenerated = false
            named.generatedFor = ""
            named.modified = Date()
            named.lastUsed = Date()
            try? await store.update(named)
        } else {
            // Which of the site's accounts it's for is yours to say; it stays, listed as a generated password.
            try? await store.markUsed(generated.id)
        }
        return true
    }

    /// The pending strong password on a site holding `password`, if there is one.
    private static func pendingGenerated(matching password: SecretString, among saved: [Credential], in store: PasswordStore) async -> Credential? {
        for candidate in saved where candidate.isPendingGenerated {
            if let stored = try? await store.password(for: candidate.id), stored.matches(password) { return candidate }
        }
        return nil
    }

    /// An account given a pending strong password by hand (the update prompt): the pending one has done its job.
    static func dropGenerated(origin: Origin, password: SecretString, in store: PasswordStore) async {
        let saved = (try? await store.credentials(for: origin)) ?? []
        if let generated = await pendingGenerated(matching: password, among: saved, in: store) { try? await store.delete(generated.id) }
    }

    /// Saves nothing by itself: decides whether to ask, and what. A strong password Zigzag filled is settled even
    /// when Zigzag doesn't `offer` to save, or never saves on the site: you chose to keep it.
    private func consider(origin: Origin, username: String, password: SecretString, isChange: Bool, offers: Bool, in tab: Tab) async {
        let store = PasswordStore.shared
        if await Self.settleGenerated(origin: origin, username: username, password: password, in: store) {
            guard offers, await !store.neverSaves(on: origin) else { return }
            // A change form with no username, on a site with one account saved: that one is offered the new
            // password, for you to say so, as a typed one would be. The pending one keeps it meanwhile.
            let named = ((try? await store.credentials(for: origin)) ?? []).filter { !$0.username.isEmpty && !$0.isPendingGenerated }
            if isChange, username.isEmpty, named.count == 1, let account = named.first {
                if let current = try? await store.password(for: account.id), current.matches(password) { return }
                SavePasswordPrompt.show(.update(account), origin: origin, password: password, in: tab)
            }
            return
        }
        guard offers, await !store.neverSaves(on: origin) else { return }
        let saved = ((try? await store.credentials(for: origin)) ?? []).filter { !$0.isPendingGenerated }
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
      // A press that may send the form a strong password was filled into (Zigzag marks those fields), for pages that
      // send it by script: a button, or a link that goes nowhere, in its form if it has one, but not one to cancel,
      // go back, show the password or follow a link; or Return in one of its fields.
      const generatedForm = () => {
        const marked = (window.__zigzagGenerated || []).filter((el) => el.isConnected && el.value);
        return marked.length ? { form: marked[0].form } : null;
      };
      const staysHere = /cancel|back|close|dismiss|show|hide|reveal|forgot|reset|visib|取消|返回|关闭|显示|隐藏|忘记/i;
      document.addEventListener('click', (e) => {
        if (!e.isTrusted || !e.target || !e.target.closest) return;
        const generated = generatedForm();
        if (!generated) return;
        const el = e.target.closest('button, input[type=submit], input[type=button], input[type=image], [role=button], a');
        if (!el || staysHere.test(label(el))) return;
        const href = el.tagName === 'A' ? (el.getAttribute('href') || '') : '';
        if (href && href !== '#' && !/^javascript:/i.test(href)) return;
        if (generated.form && el.form !== generated.form && !generated.form.contains(el)) return;
        post({ kind: 'attempt' });
      }, true);
      document.addEventListener('keydown', (e) => {
        if (!e.isTrusted || e.key !== 'Enter' || e.isComposing || !e.target || e.target.tagName !== 'INPUT') return;
        const generated = generatedForm();
        if (generated && (!generated.form || e.target.form === generated.form)) post({ kind: 'attempt' });
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

/// Password-manager extensions. Where one is installed and on, it handles passwords and Zigzag stays out of the way:
/// in that profile, since each profile has its own extensions.
enum PasswordManagers {
    /// Each by the ID the Chrome Web Store gives it, with the name people know it by.
    static let known: [String: String] = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa": "1Password",
        "nngceckbapebfimnlniiiahkandclblb": "Bitwarden",
        "hdokiejnpimakedhajhdlcegeplioahd": "LastPass",
        "fdjamakpfbbddfjaooikfcpapjohcfmg": "Dashlane",
        "ghmbeldphafepmbegfdlkpapadhbakde": "Proton Pass",
        "bfogiafebfohielmmehodmfbbebbbpei": "Keeper",
        "eiaeiblijfjekdanodkjadfinkhbfgcd": "NordPass",
        "pejdijmoenmkgeppbflobdenhhabjlaj": "iCloud Passwords",
    ]

    /// The password manager installed and turned on in a profile, by name. Read from what the profile has
    /// installed, not from what's running: asking never starts a profile's extensions, and pages restored at
    /// launch, before extensions finish loading, already get it right.
    static func active(in profile: Profile) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        return active(among: known.keys.filter { profile.installs.isEnabled($0) && profile.installs.isInstalled($0) })
    }

    /// With several on, the first by name, so the answer doesn't change from one time to the next.
    static func active(among ids: [String]) -> String? { ids.compactMap { known[$0] }.sorted().first }

    /// Whether Zigzag itself saves or fills in a profile: what you chose there; until you choose, yes, unless a
    /// password manager is on there. `imported`: passwords were brought over from another browser, which are
    /// there to be filled even so.
    static func zigzagHandles(chosen: Bool?, managerOn: Bool, imported: Bool = false) -> Bool {
        chosen ?? (!managerOn || imported)
    }
}
