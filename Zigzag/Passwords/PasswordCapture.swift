import AppKit
import WebKit

/// Notices logins as they happen and offers to save them. The watching script runs in Zigzag's own script
/// world, where neither the page nor extensions can see it; the password goes from its message straight into
/// a `SecretString`, and nothing about it is logged.
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
        Task { await self.consider(origin: origin, username: username, password: password, isChange: kind == "change", in: tab) }
    }

    /// Saves nothing by itself: decides whether to ask, and what.
    private func consider(origin: Origin, username: String, password: SecretString, isChange: Bool, in tab: Tab) async {
        let store = PasswordStore.shared
        guard await !store.neverSaves(on: origin) else { return }
        let saved = (try? await store.credentials(for: origin)) ?? []
        // A change form often has no username; if there's one login for the site, it's that one.
        let target = saved.first { $0.username == username } ?? (isChange && username.isEmpty && saved.count == 1 ? saved.first : nil)
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
    /// typed password (sites that sign in without a form). Hidden fields are ignored.
    private static let watcher = """
    (() => {
      if (window.__zigzagPasswordWatcher) return;
      window.__zigzagPasswordWatcher = true;
      const post = (message) => { try { window.webkit.messageHandlers.zigzagPassword.postMessage(message); } catch (e) {} };
      const visible = (el) => {
        if (!el || el.type === 'hidden' || el.disabled) return false;
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
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
      let typed = new WeakSet(), last = '';
      document.addEventListener('input', (e) => { if (e.target && e.target.type === 'password') typed.add(e.target); }, true);
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
        const signature = chosen.value.length + ':' + location.href;
        if (signature === last) return;
        last = signature;
        post({ kind: change ? 'change' : 'login', username: usernameBefore(passwords[0], scope), password: chosen.value });
      };
      document.addEventListener('submit', (e) => capture(e.target), true);
      document.addEventListener('click', (e) => {
        const button = e.target && e.target.closest ? e.target.closest('button, input[type=submit], [role=button]') : null;
        if (button) capture(button.form || button.closest('form') || document);
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target && e.target.tagName === 'INPUT') capture(e.target.form || document);
      }, true);
      window.addEventListener('pagehide', () => {
        if (fields(document).some((el) => el.type === 'password' && el.value && typed.has(el))) capture(document);
      });
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
        return ExtensionHost.shared.contexts.first { extensionIDs.contains($0.uniqueIdentifier) }?.webExtension.displayName
    }
}
