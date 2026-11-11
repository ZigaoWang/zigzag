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
    /// Set once passwords have been imported.
    static let importedKey = "PasswordsImported"
    static let importedAtKey = "PasswordsImportedAt"
    /// Sites that already said "no saved password" this session; once is enough.
    private var toldMissing: Set<String> = []
    private var offeredImport = false

    /// Nothing saved here and nothing ever imported, with another browser on this Mac: the first sign-in of the
    /// session offers to bring its passwords over (once; skipping the import in onboarding is easy to regret).
    private func browserToImport() -> String? {
        guard !offeredImport, !UserDefaults.standard.bool(forKey: Self.importedKey) else { return nil }
        let sources = ImportCoordinator.detectedSources().filter { if case .file = $0.kind { false } else { true } }
        let suggested = ImportCoordinator.suggested(sources)
        guard let source = sources.first(where: { suggested.contains($0.id) }) ?? sources.first else { return nil }
        offeredImport = true
        switch source.kind {
        case .chromium(let browser): return browser.name
        case .firefox(let browser): return browser.name
        case .safari: return "Safari"
        case .orion: return OrionImporter.name
        case .file: return nil
        }
    }

    /// Soon after an import, a sign-in with nothing saved says so, instead of leaving you to think the import
    /// failed (Chrome, for one, doesn't keep the password of the Google account you're signed in to it with).
    private func shouldSayMissing(on origin: Origin) -> Bool {
        guard let at = UserDefaults.standard.object(forKey: Self.importedAtKey) as? Date, Date().timeIntervalSince(at) < 14 * 24 * 3600 else { return false }
        let site = PublicSuffix.registrableDomain(origin.host) ?? origin.host
        return toldMissing.insert(site).inserted
    }

    private var menu: AutofillMenu?
    /// The frame and field the menu belongs to.
    private var target: (webView: BrowserWebView, frame: WKFrameInfo, origin: Origin)?
    /// Bumped on every focus change, so a slow vault lookup for an old field never shows a menu.
    private var generation = 0
    /// The new-password field's own rules, for the generator.
    private var rules = PasswordGenerator.Rules()

    /// Offer saved logins in sign-in fields. On by default, unless a password-manager extension is handling them
    /// and Zigzag has no passwords brought over from another browser.
    static func isOn(in profile: Profile) -> Bool {
        PasswordManagers.zigzagHandles(chosen: ProfileKey.fillsPasswords.choice(in: profile.id), managerOn: PasswordManagers.active(in: profile) != nil,
                                       imported: UserDefaults.standard.bool(forKey: importedKey))
    }

    static func setOn(_ on: Bool, in profile: Profile) {
        UserDefaults.standard.set(on, forKey: ProfileKey.fillsPasswords.name(in: profile.id))
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
            debugLog("autofill focus main=\(message.frameInfo.isMainFrame) on=\(Self.isOn(in: Profiles.shared.profile(ofPage: webView))) form=\(body["isForm"] ?? "-") new=\(body["isNew"] ?? "-")")
            // Fields inside frames are positioned relative to the frame, which the page can't tell us reliably.
            guard message.frameInfo.isMainFrame, Self.isOn(in: Profiles.shared.profile(ofPage: webView)),
                  let rect = body["rect"] as? [String: Double], let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] else { hide(); return }
            let security = message.frameInfo.securityOrigin
            let origin = Origin(scheme: security.protocol, host: security.host.lowercased(), port: security.port == 0 ? nil : security.port)
            // The page measures in CSS pixels; at a site's zoom, each is pageZoom points.
            let zoom = webView.pageZoom
            let field = NSRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
            let frame = message.frameInfo
            #if DEBUG
            lastFrame = frame
            #endif
            let current = generation
            // A name, email, phone or address field: offer your card from Contacts. Read only once you pick it.
            if body["isForm"] as? Bool == true {
                guard ContactCard.isOn, !(webView.owner?.isPrivate ?? false) else { hide(); return }
                show([.contact], under: field, in: webView, frame: frame, origin: origin)
                return
            }
            let isNew = body["isNew"] as? Bool == true
            let isPrivate = webView.owner?.isPrivate ?? false
            if isNew {
                rules = PasswordGenerator.Rules(passwordRules: body["rules"] as? String ?? "", minLength: body["minLength"] as? Int ?? -1,
                                                maxLength: body["maxLength"] as? Int ?? -1)
            }
            Task {
                let all: [Credential]
                var readable = true
                do { all = try await PasswordStore.shared.all() } catch { debugLog("autofill vault error \(error)"); all = []; readable = false }
                let logins = all.filter { $0.origin.fills(on: origin) }
                debugLog("autofill \(origin.host): \(logins.count) of \(all.count) match")
                guard current == self.generation else { return }
                // A field for a new password offers a strong one first, and still your saved logins under it: a
                // sign-in Zigzag takes for a sign-up (or a change of password) is still yours to fill.
                if isNew {
                    self.show(Self.menuItems(logins, on: origin, newPassword: true, isPrivate: isPrivate), under: field, in: webView, frame: frame, origin: origin)
                    return
                }
                // Nothing saved here: Passwords… is what's left, with a word on why above it when there's one.
                if logins.isEmpty {
                    var hint: [AutofillMenu.Item] = []
                    if !all.isEmpty, self.shouldSayMissing(on: origin) {
                        hint = [.missing]
                    } else if readable, all.isEmpty, let browser = self.browserToImport() {
                        hint = [.importFrom(browser)]
                    }
                    self.show(hint + Self.menuItems([], on: origin), under: field, in: webView, frame: frame, origin: origin)
                    return
                }
                self.show(Self.menuItems(logins, on: origin), under: field, in: webView, frame: frame, origin: origin)
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

    /// The rows for the logins that may fill on `origin`: those saved for this host, newest used first, then one quiet
    /// row standing for those saved for other parts of the site, which list only once you pick it. A login of
    /// another subdomain is never one click away.
    ///
    /// On a field for a new password, "Use Strong Password" comes first and the logins follow, as in Safari; in a
    /// private window, which keeps no new password, a row says so in its place.
    ///
    /// Passwords… (the Mac's own list: the Passwords app and password manager apps) is always last, in private
    /// windows too: what it fills is never saved anywhere.
    static func menuItems(_ logins: [Credential], on origin: Origin, newPassword: Bool = false, isPrivate: Bool = false,
                          systemPasswords: Bool = true) -> [AutofillMenu.Item] {
        let lead: [AutofillMenu.Item] = newPassword ? [isPrivate ? .note(.privateWindow) : .generate] : []
        let tail: [AutofillMenu.Item] = systemPasswords ? [.systemPasswords] : []
        let newest: (Credential, Credential) -> Bool = { a, b in
            if a.origin.isExact(for: origin) != b.origin.isExact(for: origin) { return a.origin.isExact(for: origin) }
            return (a.lastUsed ?? a.modified) > (b.lastUsed ?? b.modified)
        }
        let here = logins.filter { $0.origin.host == origin.host }.sorted(by: newest)
        let elsewhere = logins.filter { $0.origin.host != origin.host }.sorted(by: newest)
        let room = AutofillMenu.maxRows - lead.count - tail.count
        guard !elsewhere.isEmpty else { return lead + here.prefix(room).map { .login($0) } + tail }
        return lead + here.prefix(room - 1).map { .login($0) } + [.elsewhere(elsewhere)] + tail
    }

    /// Where the menu showing was put: picking "other parts of the site" lists them in the same place.
    private var field = NSRect.zero

    private func show(_ items: [AutofillMenu.Item], under field: NSRect, in webView: BrowserWebView, frame: WKFrameInfo, origin: Origin) {
        guard let overlay = Self.overlay(for: webView) else { return }
        self.field = field
        menu?.removeFromSuperview()
        let menu = AutofillMenu(items: Array(items.prefix(AutofillMenu.maxRows)), origin: origin)
        menu.onPick = { [weak self] item in self?.pick(item) }
        let fieldInOverlay = overlay.convert(webView.convert(field, to: nil), from: nil)
        let width = min(max(fieldInOverlay.width, 260), 360)
        let height = menu.contentHeight
        var y = fieldInOverlay.maxY + Tokens.Space.x1
        if y + height > overlay.bounds.maxY - Tokens.Space.x2 { y = fieldInOverlay.minY - Tokens.Space.x1 - height }
        let x = min(max(fieldInOverlay.minX, Tokens.Space.x2), overlay.bounds.maxX - width - Tokens.Space.x2)
        menu.frame = NSRect(x: x, y: y, width: width, height: height)
        overlay.addSubview(menu)
        menu.present()
        self.menu = menu
        target = (webView, frame, origin)
        setSuggesting(true)
    }

    var isShowing: Bool { menu != nil }

    /// Where the menu floats over a page: its browser window's overlay, or Zigzag Mini's.
    private static func overlay(for webView: WKWebView) -> NSView? {
        if let controller = WindowManager.shared.controller(for: webView.window) { return controller.root.overlay }
        return MiniWindowController.all.first { $0.tab.webView === webView }?.overlay
    }

    /// The page is the one on screen in its window: the selected tab's, the page peeked at over it (a sign-in a
    /// site opens in a window of its own comes up there), or Zigzag Mini's only page.
    static func isInFront(_ webView: WKWebView) -> Bool {
        if let controller = WindowManager.shared.controller(for: webView.window) {
            if controller.peek.isVisible { return controller.peek.tab?.webView === webView }
            return controller.selectedWebView === webView
        }
        return MiniWindowController.all.contains { $0.tab.webView === webView && $0.window === webView.window }
    }

    #if DEBUG
    private var lastFrame: WKFrameInfo?
    /// For the debug bridge: one of the hint rows under a spot on the page, with no vault involved.
    func debugShow(_ kind: String, in webView: BrowserWebView) {
        guard let origin = Origin(webView.url), let frame = lastFrame else { return }
        let item: AutofillMenu.Item = kind == "missing" ? .missing : .importFrom("Chrome")
        show([item], under: NSRect(x: 40, y: 120, width: 320, height: 32), in: webView, frame: frame, origin: origin)
    }

    /// The menu's rows, for the debug log.
    var debugRows: [String] { menu?.debugRows ?? [] }

    /// A mouse down and up on the middle of `view`'s `rect`, sent to its window as a click would arrive.
    private static func debugSendClick(at rect: NSRect, in view: NSView) {
        guard let window = view.window, let content = window.contentView?.superview else { return }
        let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        // Straight to the view under the point, as the window passes a click on: a test copy in the background
        // (another app in front) would otherwise take it as the click that only brings the window forward.
        guard let target = content.hitTest(content.convert(point, from: nil)) else { return }
        debugLog("autofill debug click on \(type(of: target))")
        if window.firstResponder !== target, target.acceptsFirstResponder { window.makeFirstResponder(target) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
    }

    /// For the debug bridge: a click on the page element `selector` matches, as a person's click reaches the page.
    /// `selector@x,y` clicks that far from the element's top left corner instead of its middle.
    static func debugClick(_ spec: String, in webView: WKWebView) {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        let selector = parts[0]
        let offset = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
        Task {
            let rect = try? await webView.callAsyncJavaScript("const r = document.querySelector(s).getBoundingClientRect(); return [r.left, r.top, r.width, r.height]",
                                                              arguments: ["s": selector], in: nil, contentWorld: .defaultClient) as? [Double]
            guard let rect, rect.count == 4 else { debugLog("autofillclick: no \(selector)"); return }
            let zoom = webView.pageZoom
            // Page coordinates run down from the top; the web view is flipped the same way.
            var local = offset.count == 2 ? NSRect(x: (rect[0] + offset[0]) * zoom - 1, y: (rect[1] + offset[1]) * zoom - 1, width: 2, height: 2)
                : NSRect(x: rect[0] * zoom, y: rect[1] * zoom, width: rect[2] * zoom, height: rect[3] * zoom)
            if !webView.isFlipped { local.origin.y = webView.bounds.height - local.maxY }
            debugSendClick(at: local, in: webView)
        }
    }

    /// For the debug bridge: a click on a row of the menu showing, once Zigzag is the app in front (the Mac's list
    /// of passwords opens only for that), waiting up to five seconds for it.
    func debugPickWhenActive(_ row: Int, tries: Int = 0) {
        guard NSApp.isActive, NSApp.keyWindow != nil else {
            guard tries < 50 else { debugLog("autofillpickactive: never in front"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.debugPickWhenActive(row, tries: tries + 1) }
            return
        }
        debugPick(row)
    }

    /// For the debug bridge: a click on a row of the menu showing.
    func debugPick(_ row: Int) {
        guard let menu, let frame = menu.debugRowFrame(row) else { debugLog("autofillpick: no row \(row)"); return }
        Self.debugSendClick(at: frame, in: menu)
    }
    #endif

    func hide() {
        guard let menu else { target = nil; return }
        setSuggesting(false)
        self.menu = nil
        target = nil
        menu.dismiss()
    }

    /// A page going away (its tab closed or put to sleep, its window closed): the menu lets go of it, so nothing
    /// keeps the page alive (and playing) after it's gone.
    func forget(_ webView: WKWebView) {
        if target?.webView === webView { hide() }
        if systemRequest?.webView === webView { SystemPasswordPicker.shared.cancel() }
    }

    /// The same for every page in a window that's closing.
    func forget(windowOf window: NSWindow?) {
        if let window, target?.webView.window === window { hide() }
        if let window, systemRequest?.webView.window === window { SystemPasswordPicker.shared.cancel() }
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
        case .elsewhere(let logins):
            // The same field, now with the logins of the site's other addresses: picking one is a second, deliberate step.
            guard let target, Self.isInFront(target.webView) else { hide(); return }
            show(logins.map { .login($0) }, under: field, in: target.webView, frame: target.frame, origin: target.origin)
        case .generate: fillGenerated()
        case .contact: fillContact()
        case .systemPasswords: openSystemPasswords()
        // Says why something isn't offered; nothing to do.
        case .note: break
        case .importFrom:
            hide()
            ImportWindowController.show()
        case .missing:
            let site = target.map { PublicSuffix.registrableDomain($0.origin.host) ?? $0.origin.displayName } ?? ""
            hide()
            // "google.com" finds logins saved under any part of it.
            PasswordsWindowController.show(searching: site.split(separator: ".").first.map(String.init) ?? site)
        }
    }

    /// A short word in the page's window about a fill that didn't happen, so a pick never just does nothing.
    private static func tell(_ text: String, about webView: WKWebView) {
        if let controller = WindowManager.shared.controller(for: webView.window) {
            Toast.show(text, symbol: "exclamationmark.triangle", duration: 4, in: controller)
        } else {
            NSSound.beep()
        }
    }

    private static var noPasswordField: String {
        String(localized: "Zigzag couldn’t find a password field it can see on this page. Copy the password from Passwords instead.", comment: "Toast when a login or strong password was picked but the page has no visible password field to put it in. Passwords is the window.")
    }

    private static var pageMovedOn: String {
        String(localized: "This page changed before Zigzag could fill it. Click the field again.", comment: "Toast when a login or strong password was picked but the page went to another site, or its tab was no longer in front.")
    }

    /// Fills a new strong password into the form's new-password fields, and saves it right away, so it's never
    /// lost if the sign-up's submit goes unnoticed. The username is added when the form is sent.
    private func fillGenerated() {
        // As the other fills do: only into the page the menu was for, still on that site, in the tab you're looking at.
        guard let target else { hide(); return }
        guard Origin(target.webView.url) == target.origin, Self.isInFront(target.webView) else { hide(); Self.tell(Self.pageMovedOn, about: target.webView); return }
        let origin = target.origin
        let webView = target.webView
        hide()
        let candidates = PasswordGenerator.candidates(rules, count: 6)
        Task {
            let arguments: [String: Any] = ["candidates": candidates.map { $0.withUnsafeString { String($0) } }]
            // Checked again right before filling: the page may have moved on while the menu was open.
            guard Origin(webView.url) == origin, Self.isInFront(webView) else { Self.tell(Self.pageMovedOn, about: webView); return }
            let result = try? await webView.callAsyncJavaScript(Self.generatedFiller, arguments: arguments, in: target.frame, contentWorld: .defaultClient) as? [String: Any]
            let controller = WindowManager.shared.controller(for: webView.window)
            guard let index = result?["index"] as? Int, candidates.indices.contains(index) else {
                if result?["noField"] as? Bool == true {
                    Self.tell(Self.noPasswordField, about: webView)
                } else {
                    Self.tell(String(localized: "This site’s password rules didn’t fit a strong password. Type one yourself.", comment: "Toast when Zigzag couldn't make a strong password the site accepts."), about: webView)
                }
                return
            }
            let password = candidates[index]
            let username = result?["username"] as? String
            do {
                // With no username on the form, nothing says which login this is: it's kept as a new one, never over
                // another saved without a name (an account made earlier), whose password would be lost.
                let named = !(username ?? "").isEmpty
                try await PasswordStore.shared.save(origin: origin, username: username ?? "", password: password, replacingExisting: named)
                if let controller { Toast.show(String(localized: "Strong password saved for \(origin.displayName)", comment: "Toast after a strong password was filled and saved. The placeholder is a site, like github.com."), symbol: "key", duration: 2, in: controller) }
            } catch {
                if let controller { Toast.show(String(localized: "Couldn’t save the new password. Copy it before you leave this page.", comment: "Toast when a strong password was filled but couldn't be saved."), symbol: "exclamationmark.triangle", duration: 4, in: controller) }
            }
        }
    }

    /// Fills the form's name, email, phone, company and address fields from your card, leaving anything typed alone.
    private func fillContact() {
        guard let target else { return }
        hide()
        // As with a login: still the site the menu was offered on, in the tab you're looking at. Checked again once
        // the card is read (asking for Contacts can take a while), and by the page script as it fills.
        let stillThere = {
            Origin(target.webView.url) == target.origin
                && Self.isInFront(target.webView)
        }
        guard stillThere() else { return }
        Task {
            guard let values = await ContactCard.values() else {
                if let controller = WindowManager.shared.controller(for: target.webView.window) {
                    Toast.show(String(localized: "Zigzag can’t read your card. Allow it in System Settings › Privacy › Contacts, and set My Card in Contacts.", comment: "Toast when filling a form from Contacts isn't allowed. System Settings › Privacy › Contacts and My Card are names macOS uses; match them."),
                               symbol: "person.crop.circle.badge.exclamationmark", duration: 5, in: controller)
                }
                return
            }
            guard stillThere() else { return }
            let arguments: [String: Any] = ["values": values, "expectedOrigin": target.origin.description]
            _ = try? await target.webView.callAsyncJavaScript(Self.formFiller, arguments: arguments, in: target.frame, contentWorld: .defaultClient)
        }
    }

    /// The page Passwords… was chosen on, while the Mac's list is open.
    private(set) var systemRequest: (webView: BrowserWebView, frame: WKFrameInfo, origin: Origin)?

    /// Passwords…: the Mac's own list, opened at the field. What you pick in it goes into the page only if it's still
    /// the site it was asked for, in the tab you're looking at; it's never saved, in Zigzag or anywhere.
    private func openSystemPasswords() {
        guard let target else { hide(); return }
        guard Origin(target.webView.url) == target.origin, Self.isInFront(target.webView), let overlay = Self.overlay(for: target.webView) else {
            hide(); Self.tell(Self.pageMovedOn, about: target.webView); return
        }
        let request = target
        let rect = overlay.convert(target.webView.convert(field, to: nil), from: nil)
        hide()
        systemRequest = request
        SystemPasswordPicker.shared.present(over: rect, in: overlay, restoringFocusTo: request.webView) { [weak self] outcome in
            guard let self else { return }
            if self.systemRequest?.webView === request.webView { self.systemRequest = nil }
            switch outcome {
            case .filled(let username, let password):
                self.fillFromSystem(username: username, password: password, into: request)
            case .cancelled(.unavailable):
                Self.tell(String(localized: "Passwords didn’t open. Click the field and try again.", comment: "Toast when Passwords… was chosen in the fill-password menu but the Mac's list of passwords couldn't be shown."), about: request.webView)
            case .cancelled: break
            }
        }
    }

    /// Fills what the Mac's list gave into the page Passwords… was chosen on, then lets go of it.
    func fillFromSystem(username: SecretString, password: SecretString, into request: (webView: BrowserWebView, frame: WKFrameInfo, origin: Origin)) {
        let webView = request.webView
        guard Self.systemFillAllowed(asked: request.origin, now: webView.url, inFront: Self.isInFront(webView)) else { Self.tell(Self.pageMovedOn, about: webView); return }
        Task {
            // Passed as arguments, never pasted into the script's source, held only for the call, and not marked as
            // Zigzag's own fill: signing in with it never offers to save it.
            let arguments: [String: Any] = ["username": username.withUnsafeString { String($0) }, "password": password.withUnsafeString { String($0) },
                                            "expectedOrigin": request.origin.description, "mark": false]
            let filled = try? await webView.callAsyncJavaScript(Self.filler, arguments: arguments, in: request.frame, contentWorld: .defaultClient) as? [String: Any]
            guard let filled, filled["moved"] as? Bool != true else { Self.tell(Self.pageMovedOn, about: webView); return }
            guard filled["password"] as? Bool == true || filled["username"] as? Bool == true else { Self.tell(Self.noPasswordField, about: webView); return }
            // Only a password came back, and the username field is still empty: say so, or it looks like a slip.
            if username.isEmpty, filled["usernameEmpty"] as? Bool == true, let controller = WindowManager.shared.controller(for: webView.window) {
                Toast.show(String(localized: "Only the password was filled. Type your username.", comment: "Toast after a login picked from the Mac's list of passwords came back without a username."),
                           symbol: "key", duration: 3, in: controller)
            }
        }
    }

    /// A login from the Mac's list goes only to the exact site it was asked for, in the tab you're looking at.
    static func systemFillAllowed(asked: Origin, now: URL?, inFront: Bool) -> Bool {
        Origin(now) == asked && inFront
    }

    private func fill(_ login: Credential) {
        guard let target else { return }
        hide()
        // The page may have moved on since the menu opened: it must still be the login's own site, in the tab
        // you're looking at. The page script checks again at the moment it fills.
        guard login.origin.fills(on: target.origin), Origin(target.webView.url) == target.origin,
              Self.isInFront(target.webView) else { Self.tell(Self.pageMovedOn, about: target.webView); return }
        Task {
            guard let password = try? await PasswordStore.shared.password(for: login.id) else {
                if let controller = WindowManager.shared.controller(for: target.webView.window) {
                    Toast.show(String(localized: "Couldn’t open that password. Try again from the Passwords window.", comment: "Toast when a saved password couldn't be read to fill a form."), symbol: "exclamationmark.triangle", duration: 3, in: controller)
                }
                return
            }
            // Passed as an argument, never pasted into the script's source, and held only for the call.
            let arguments: [String: Any] = ["username": login.username, "password": password.withUnsafeString { String($0) },
                                            "expectedOrigin": target.origin.description]
            let filled = try? await target.webView.callAsyncJavaScript(Self.filler, arguments: arguments, in: target.frame, contentWorld: .defaultClient) as? [String: Any]
            if filled?["moved"] as? Bool == true { Self.tell(Self.pageMovedOn, about: target.webView); return }
            // No field it could see to put the login in: it says so, and the password is a click away in Passwords. (A
            // first step that asks only for the username fills just that.)
            guard filled?["password"] as? Bool == true || filled?["username"] as? Bool == true else { Self.tell(Self.noPasswordField, about: target.webView); return }
            // Private windows leave no trace, not even "last used".
            if !(target.webView.owner?.isPrivate ?? false) { try? await PasswordStore.shared.markUsed(login.id) }
        }
    }

    /// Whether a field is one you sign in with: a password (not a new one), or the username beside one.
    static let signInCheck = """
    const signIn = (el) => {
        if (!el || el.tagName !== 'INPUT' || el.disabled || el.readOnly) return false;
        if (el.type === 'password') return !/new-password/.test(el.autocomplete || '');
        if (!['text', 'email', 'tel', ''].includes(el.type)) return false;
        if (/username|email/.test(el.autocomplete || '')) return true;
        const scope = el.form || document;
        return !!scope.querySelector('input[type=password]') && /user|login|email|account|id|name/i.test((el.name || '') + (el.id || '') + (el.placeholder || '') + (el.getAttribute('aria-label') || ''));
      };
    """

    /// Reports focus on sign-in fields (with the field's place on screen), blur, and the keys the menu takes.
    private static let watcher = """
    (() => {
      if (window.__zigzagAutofillWatcher) return;
      window.__zigzagAutofillWatcher = true;
      const post = (m) => { try { window.webkit.messageHandlers.zigzagAutofill.postMessage(m); } catch (e) {} };
      \(signInCheck)
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
      // A field for your own details: says so in autocomplete, or by its name (but never a search box or a sign-in).
      const formField = (el) => {
        if (!el || el.tagName !== 'INPUT' || el.disabled || el.readOnly || el.value) return false;
        if (!['text', 'email', 'tel', ''].includes(el.type) || signIn(el)) return false;
        const auto = (el.autocomplete || '').toLowerCase();
        if (/\\b(name|given-name|family-name|email|tel|organization|street-address|address-line1|postal-code|address-level1|address-level2|country-name)\\b/.test(auto)) return true;
        if (auto === 'off' || /search/i.test(el.type + el.name + el.id + (el.getAttribute('role') || ''))) return false;
        const hint = (el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || '') + ' ' + (el.getAttribute('aria-label') || '');
        return /first.?name|last.?name|full.?name|your.?name|^name$|e-?mail|phone|mobile|address|street|city|zip|postal|postcode|company|organi[sz]ation/i.test(hint.trim());
      };
      const report = (el) => {
        const r = el.getBoundingClientRect();
        post({ kind: 'focus', isForm: formField(el), isNew: isNew(el) && !el.value, rules: el.getAttribute('passwordrules') || '',
               minLength: el.minLength, maxLength: el.maxLength, rect: { x: r.left, y: r.top, w: r.width, h: r.height } });
      };
      const wanted = (el) => signIn(el) || isNew(el) || formField(el);
      // The menu opens only for something you did: a click on the field, or Tab to it. A page can put the cursor in a
      // field by itself, and mustn't get the menu up under a click you were about to make elsewhere.
      let pressed = null, pressedAt = -Infinity, pressX = 0, pressY = 0;
      // A click on the field's own box counts, whatever the page put there: its label, the box around it (a field
      // with an icon in it, whose page focuses it for you), or a placeholder laid over it until you type.
      const onField = (el) => {
        if (pressed === el || [...(el.labels || [])].some((label) => label === pressed || label.contains(pressed))) return true;
        const r = el.getBoundingClientRect(), m = 8;
        if (pressX >= r.left - m && pressX <= r.right + m && pressY >= r.top - m && pressY <= r.bottom + m) return true;
        if (!(pressed instanceof Element) || !pressed.contains(el)) return false;
        const b = pressed.getBoundingClientRect();
        return b.width <= r.width + 120 && b.height <= r.height * 2 + 24;
      };
      const byYou = (el) => performance.now() - pressedAt < 1000 && (pressed === 'Tab' || onField(el));
      // Pointer down first: a page that handles presses itself can stop the mouse events that follow, never this one.
      const press = (e) => {
        if (!e.isTrusted || e.button !== 0) return;
        const again = e.type === 'mousedown' && pressed === e.target && performance.now() - pressedAt < 500;
        pressed = e.target; pressedAt = performance.now(); pressX = e.clientX; pressY = e.clientY;
        // A click on a field the cursor is already in (one the page put it in when it opened) brings the menu too.
        const active = document.activeElement;
        if (!again && !window.__zigzagFilling && active && wanted(active) && onField(active)) report(active);
      };
      document.addEventListener('pointerdown', press, true);
      document.addEventListener('mousedown', press, true);
      document.addEventListener('focusin', (e) => { if (!window.__zigzagFilling && wanted(e.target) && byYou(e.target)) report(e.target); }, true);
      document.addEventListener('focusout', (e) => { if (wanted(e.target)) post({ kind: 'blur' }); }, true);
      document.addEventListener('input', (e) => { if (window.__zigzagSuggesting && wanted(e.target)) post({ kind: 'blur' }); }, true);
      window.addEventListener('scroll', () => { if (window.__zigzagSuggesting) post({ kind: 'blur' }); }, true);
      document.addEventListener('keydown', (e) => {
        if (!e.isTrusted) return;
        if (e.key === 'Tab') { pressed = 'Tab'; pressedAt = performance.now(); }
        // A field the page put the cursor in when it opened (Google's sign-in does): the menu comes with a click on it,
        // or the down arrow.
        if (e.key === 'ArrowDown' && !window.__zigzagSuggesting && !window.__zigzagFilling && e.target === document.activeElement && wanted(e.target)) {
          report(e.target);
          return;
        }
        // Only keys a person pressed: a page can send itself key events, but must never pick a login with them.
        if (!window.__zigzagSuggesting || !['ArrowDown', 'ArrowUp', 'Enter', 'Escape'].includes(e.key)) return;
        if (e.key === 'Enter' && !window.__zigzagSelected) return;
        e.preventDefault(); e.stopPropagation();
        post({ kind: 'key', key: e.key });
      }, true);
    })();
    """

    /// Whether what covers a field at (x, y) is only something laid over it inside its own box, as an old-style
    /// placeholder is ("Password" in a span over the field, gone once you type): the field is still the one you see.
    /// Anything larger, or anything you could type in or press, hides it.
    static let placeholderCheck = """
    const placeholderOver = (el, x, y) => {
      const stack = document.elementsFromPoint(x, y), at = stack.indexOf(el);
      if (at <= 0) return false;
      const r = el.getBoundingClientRect(), m = 4;
      return stack.slice(0, at).every((over) => {
        if (/^(INPUT|SELECT|TEXTAREA|BUTTON|A|IFRAME|IMG|VIDEO|CANVAS|OBJECT|EMBED)$/.test(over.tagName)) return false;
        if (over.querySelector('input, select, textarea, button, a, iframe')) return false;
        const b = over.getBoundingClientRect();
        return b.left >= r.left - m && b.top >= r.top - m && b.right <= r.right + m && b.bottom <= r.bottom + m;
      });
    };

    """

    /// Picks the first candidate the field accepts (its `pattern` and lengths), puts it in every new-password
    /// field of the focused form (the password and its confirmation), and returns its index and the username
    /// typed so far, if any.
    static let generatedFiller = placeholderCheck + """
    const active = document.activeElement;
    const scope = (active && active.form) || document;
    // Only fields a person can see: a real size, on the page, not transparent or hidden by an ancestor.
    // Your phone and address go only where you could see them land: on the page across, near where you are
    // (a long checkout form runs on below), not clipped away inside a tiny box, and not covered by something else.
    const visible = (el) => {
      if (el.disabled || el.readOnly || el.type === 'hidden') return false;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8) return false;
      if (r.right < 0 || r.left > innerWidth || r.bottom < -innerHeight || r.top > innerHeight * 3) return false;
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
      const style = getComputedStyle(el);
      if (style.visibility !== 'visible' || parseFloat(style.opacity) < 0.1) return false;
      for (let box = el.parentElement; box && box !== document.body; box = box.parentElement) {
        const o = getComputedStyle(box);
        const overflow = o.overflow + o.overflowX + o.overflowY;
        if (!/(hidden|clip|scroll|auto)/.test(overflow)) continue;
        const b = box.getBoundingClientRect();
        if (b.width < 8 || b.height < 8) return false;
        // A scrolling box can be scrolled to what's below; one that clips can't.
        if (!/(hidden|clip)/.test(overflow)) continue;
        const w = Math.min(r.right, b.right) - Math.max(r.left, b.left), h = Math.min(r.bottom, b.bottom) - Math.max(r.top, b.top);
        if (w < 8 || h < 8) return false;
      }
      if (r.top >= 0 && r.bottom <= innerHeight) {
        const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        if (hit && hit !== el && !el.contains(hit) && !(hit.control === el) && !placeholderOver(el, r.left + r.width / 2, r.top + r.height / 2)) return false;
      }
      return true;
    };
    const inputs = [...scope.querySelectorAll('input')].filter(visible);
    const passwords = inputs.filter((el) => el.type === 'password');
    const current = passwords.find((el) => /current-password/.test(el.autocomplete || ''));
    const fresh = passwords.filter((el) => el !== current && (/new-password/.test(el.autocomplete || '') || !/current-password/.test(el.autocomplete || '')));
    const targets = current || passwords.length < 3 ? fresh : fresh.slice(1);
    const field = targets.includes(active) ? active : targets[0];
    if (!field) return { index: -1, noField: true };
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
    // Marked as filled by Zigzag, so sending the form still names the login just saved.
    const filled = (window.__zigzagFilled = window.__zigzagFilled || new WeakSet());
    for (const el of targets) {
      filled.add(el);
      setter.call(el, password);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    const first = passwords[0];
    const users = inputs.filter((el) => ['text', 'email', 'tel', ''].includes(el.type) && el.value && inputs.indexOf(el) < inputs.indexOf(first));
    const marked = users.find((el) => /username|email/.test(el.autocomplete || '') || el.type === 'email');
    return { index, username: (marked || users[users.length - 1] || {}).value || '' };
    """

    /// Fills the focused form's fields for your details from `values` (keyed by autocomplete token), each field found
    /// by its autocomplete attribute or else its name; selects (country, state) pick the matching option. Fields
    /// already filled in are left as they are.
    static let formFiller = """
    // Checked here, at the moment of filling: only the site the card was offered on gets it.
    if (location.origin !== expectedOrigin) return 0;
    const active = document.activeElement;
    const scope = (active && active.form) || document;
    // Your phone and address go only where you can see them land: on screen now (a field far down the page is
    // one you'd never notice filled), not clipped away inside a tiny box, and not covered by something else.
    const visible = (el) => {
      if (el.disabled || el.readOnly || el.type === 'hidden') return false;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8) return false;
      if (r.right < 0 || r.left > innerWidth || r.bottom < 0 || r.top > innerHeight) return false;
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
      const style = getComputedStyle(el);
      if (style.visibility !== 'visible' || parseFloat(style.opacity) < 0.1) return false;
      for (let box = el.parentElement; box && box !== document.body; box = box.parentElement) {
        const o = getComputedStyle(box);
        const overflow = o.overflow + o.overflowX + o.overflowY;
        if (!/(hidden|clip|scroll|auto)/.test(overflow)) continue;
        const b = box.getBoundingClientRect();
        if (b.width < 8 || b.height < 8) return false;
        // On screen means inside any box it's in too, scrolling or not.
        const w = Math.min(r.right, b.right) - Math.max(r.left, b.left), h = Math.min(r.bottom, b.bottom) - Math.max(r.top, b.top);
        if (w < 8 || h < 8) return false;
      }
      const x = Math.min(Math.max(r.left + r.width / 2, 0), innerWidth - 1), y = Math.min(Math.max(r.top + r.height / 2, 0), innerHeight - 1);
      const hit = document.elementFromPoint(x, y);
      if (hit && hit !== el && !el.contains(hit) && !(hit.control === el)) return false;
      return true;
    };
    // A form with a section for shipping and one for billing (autocomplete "section-…", "shipping", "billing"):
    // only the part you're in.
    const section = (el) => ((el && el.autocomplete) || '').toLowerCase().split(/\\s+/).filter((t) => /^(section-|shipping$|billing$)/.test(t)).join(' ');
    const here = section(active);
    const guess = (el) => {
      const auto = (el.autocomplete || '').toLowerCase().split(/\\s+/).filter((t) => !/^(section-|shipping|billing|home|work|mobile)/.test(t)).pop();
      if (auto && values[auto] !== undefined) return auto;
      if (auto === 'country') return 'country';
      const h = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || '') + ' ' + (el.getAttribute('aria-label') || '')).toLowerCase();
      if (/first.?name|given/.test(h)) return 'given-name';
      if (/last.?name|family|surname/.test(h)) return 'family-name';
      if (/e-?mail/.test(h)) return 'email';
      if (/phone|mobile|tel/.test(h)) return 'tel';
      if (/company|organi[sz]ation/.test(h)) return 'organization';
      if (/address.?(line)?.?2|apartment|suite|apt/.test(h)) return 'address-line2';
      if (/address|street/.test(h)) return 'address-line1';
      if (/city|town|locality/.test(h)) return 'address-level2';
      if (/state|province|region|county/.test(h)) return 'address-level1';
      if (/zip|postal|postcode/.test(h)) return 'postal-code';
      if (/country/.test(h)) return el.tagName === 'SELECT' ? 'country' : 'country-name';
      if (/name/.test(h)) return 'name';
      return null;
    };
    const setInput = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      el.focus(); setter.call(el, value);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const setSelect = (el, value, other) => {
      const want = [value, other].filter(Boolean).map((v) => v.toLowerCase());
      const option = [...el.options].find((o) => want.includes(o.value.toLowerCase()) || want.includes(o.text.trim().toLowerCase()));
      if (!option) return;
      el.value = option.value;
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    window.__zigzagFilling = true;
    let filled = 0;
    try {
      for (const el of [...scope.querySelectorAll('input, select')].filter((el) => visible(el) && section(el) === here)) {
        const key = guess(el);
        if (!key) continue;
        if (el.tagName === 'SELECT') {
          if (key === 'country') setSelect(el, values['country'], values['country-name']);
          else if (key === 'address-level1') setSelect(el, values['address-level1']);
          continue;
        }
        if (el.value || !['text', 'email', 'tel', ''].includes(el.type)) continue;
        const value = key === 'address-line1' && !values['address-line1'] ? values['street-address'] : values[key];
        if (value) { setInput(el, value); filled++; }
      }
    } finally { setTimeout(() => { window.__zigzagFilling = false; }, 0); }
    return filled;
    """

    /// Fills the focused form: the username field (if there is one) and the password field, the way typing would.
    /// An empty username or password leaves its field as it is. `mark` (true unless given) marks the fields as filled
    /// by Zigzag, so signing in with them counts as your login.
    static let filler = placeholderCheck + """
    // Checked here, at the moment of filling: only the exact site the login belongs to gets it.
    if (location.origin !== expectedOrigin) return { moved: true };
    const active = document.activeElement;
    const scope = (active && active.form) || document;
    // Only fields a person can see: a real size, on the page, not transparent or hidden by an ancestor.
    // Your phone and address go only where you could see them land: on the page across, near where you are
    // (a long checkout form runs on below), not clipped away inside a tiny box, and not covered by something else.
    const visible = (el) => {
      if (el.disabled || el.readOnly || el.type === 'hidden') return false;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8) return false;
      if (r.right < 0 || r.left > innerWidth || r.bottom < -innerHeight || r.top > innerHeight * 3) return false;
      if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
      const style = getComputedStyle(el);
      if (style.visibility !== 'visible' || parseFloat(style.opacity) < 0.1) return false;
      for (let box = el.parentElement; box && box !== document.body; box = box.parentElement) {
        const o = getComputedStyle(box);
        const overflow = o.overflow + o.overflowX + o.overflowY;
        if (!/(hidden|clip|scroll|auto)/.test(overflow)) continue;
        const b = box.getBoundingClientRect();
        if (b.width < 8 || b.height < 8) return false;
        // A scrolling box can be scrolled to what's below; one that clips can't.
        if (!/(hidden|clip)/.test(overflow)) continue;
        const w = Math.min(r.right, b.right) - Math.max(r.left, b.left), h = Math.min(r.bottom, b.bottom) - Math.max(r.top, b.top);
        if (w < 8 || h < 8) return false;
      }
      if (r.top >= 0 && r.bottom <= innerHeight) {
        const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        if (hit && hit !== el && !el.contains(hit) && !(hit.control === el) && !placeholderOver(el, r.left + r.width / 2, r.top + r.height / 2)) return false;
      }
      return true;
    };
    const inputs = [...scope.querySelectorAll('input')].filter(visible);
    // The password field you picked the login in, unless it's marked for a new password; then the current
    // password's field; and on a form only for new passwords (a sign-up, or a sign-in that looks like one), the
    // field you're in after all: you chose a saved login for it.
    const yours = active && active.type === 'password' && inputs.includes(active) ? active : null;
    const passwordField = (yours && !/new-password/.test(yours.autocomplete || '') ? yours : null)
      || inputs.find((el) => el.type === 'password' && !/new-password/.test(el.autocomplete || '')) || yours;
    const userFields = inputs.filter((el) => ['text', 'email', 'tel', ''].includes(el.type));
    const userField = userFields.find((el) => /username|email/.test(el.autocomplete || ''))
      || (passwordField ? userFields.filter((el) => inputs.indexOf(el) < inputs.indexOf(passwordField)).pop() : null)
      || (active && userFields.includes(active) ? active : null);
    const remember = typeof mark === 'undefined' || mark === true;
    const set = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      // Filled by Zigzag, as you asked: signing in with it counts as your login.
      if (remember) (window.__zigzagFilled = window.__zigzagFilled || new WeakSet()).add(el);
      el.focus();
      setter.call(el, value);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    // Focusing the fields to fill them mustn't bring the menu back.
    window.__zigzagFilling = true;
    try {
      if (userField && username) set(userField, username);
      if (passwordField && password) set(passwordField, password);
    } finally {
      setTimeout(() => { window.__zigzagFilling = false; }, 0);
    }
    return { password: !!(passwordField && password), username: !!(userField && username), usernameEmpty: !!(userField && !userField.value) };
    """
}

/// The list under a sign-in field: one row per saved login, newest used first, or a strong new password.
final class AutofillMenu: FloatingPanelView {
    enum Item {
        case login(Credential)
        case generate
        case contact
        /// Nothing saved for this site: a way to look.
        case missing
        /// Nothing saved at all: bring passwords over from this browser.
        case importFrom(String)
        /// Logins saved for other parts of the site (mail.example.com, signing in on www.example.com): listed only
        /// once you ask for them.
        case elsewhere([Credential])
        /// Something this field can't have, and why: a dimmed row that does nothing, rather than a menu that's
        /// quietly missing a row.
        case note(Note)
        /// The Mac's own list of passwords: the Passwords app and password manager apps.
        case systemPasswords
    }

    enum Note {
        /// A private window keeps no new password, so it offers no strong one.
        case privateWindow
    }

    /// The most rows the menu lists.
    static let maxRows = 8

    /// When it came up. For the first half second it takes no clicks, so a page can't bring it up just as you click
    /// (a "click here, fast" game) and catch that click on a login.
    private let shownAt = ProcessInfo.processInfo.systemUptime

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return ProcessInfo.processInfo.systemUptime - shownAt > 0.5 ? hit : self
    }

    /// A click on the menu that isn't on a row (or comes too soon) ends here, never on the page or window behind.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    private var rows: [AutofillRow] = []
    private let footer = TextButton(title: String(localized: "Passwords", comment: "Link at the bottom of the menu that fills a password into a page: opens the Passwords window."), font: Tokens.Font.small(.medium))
    private let footerLine = ColorView(color: Tokens.Color.separator)
    private let hasFooter: Bool
    private var selection = -1 { didSet { rows.enumerated().forEach { $0.element.isSelected = $0.offset == selection } } }
    var onPick: ((Item) -> Void)?

    private let pad = Tokens.Space.x1 + 2
    private let rowHeight = Tokens.Space.x10 + Tokens.Space.x1

    init(items: [Item], origin: Origin) {
        hasFooter = items.contains { switch $0 { case .login, .elsewhere: true; default: false } }
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
        setAccessibilityLabel(String(localized: "Passwords", comment: "What VoiceOver calls the menu that fills a password into a page."))
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

    #if DEBUG
    var debugRows: [String] { rows.map(\.debugName) }
    func debugRowFrame(_ index: Int) -> NSRect? { rows.indices.contains(index) ? rows[index].frame : nil }
    #endif

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
            name = Label(login.username.isEmpty ? String(localized: "No username", comment: "Shown in place of a login's username when it has none.") : login.username, font: Tokens.Font.body(.medium),
                         color: login.username.isEmpty ? Tokens.Color.textSecondary : Tokens.Color.textPrimary)
            detail = Label(String(localized: "Password for \(login.origin.displayName)", comment: "Under a login in the menu that fills a password into a page. The placeholder is a site, like github.com."), font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = origin.url.flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? Tokens.Symbol.image("key")
            icon.contentTintColor = Tokens.Color.textSecondary
        case .importFrom(let browser):
            name = Label(String(localized: "Bring your passwords from \(browser)", comment: "A row in the fill-password menu when nothing is saved yet. The placeholder is a browser, like Chrome."), font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
            detail = Label(String(localized: "Import them, and sign in here in one click", comment: "Under the row offering to import passwords, in the fill-password menu."), font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = Tokens.Symbol.image("square.and.arrow.down")
            icon.contentTintColor = Tokens.Color.accent
        case .elsewhere(let logins):
            let site = PublicSuffix.registrableDomain(origin.host) ?? origin.displayName
            name = Label(String(localized: "From other parts of \(site)", comment: "A quiet row in the fill-password menu: shows the logins saved for other addresses on the same site. The placeholder is a site, like example.com."), font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
            var hosts: [String] = []
            for login in logins where !hosts.contains(login.origin.displayName) { hosts.append(login.origin.displayName) }
            detail = Label(ListFormatter.localizedString(byJoining: hosts), font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = Tokens.Symbol.image("chevron.right")
            icon.contentTintColor = Tokens.Color.textSecondary
        case .missing:
            name = Label(String(localized: "No saved password for \(PublicSuffix.registrableDomain(origin.host) ?? origin.displayName)", comment: "A row in the fill-password menu. The placeholder is a site, like github.com."), font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
            detail = Label(String(localized: "Search your passwords", comment: "Under the row saying nothing is saved for a site, in the fill-password menu."), font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = Tokens.Symbol.image("key")
            icon.contentTintColor = Tokens.Color.textSecondary
        case .contact:
            name = Label(String(localized: "Fill from My Card", comment: "A row in the menu that fills a form. My Card is the person's own card in Contacts, as macOS calls it."), font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
            detail = Label(String(localized: "Name, email, phone and address, from Contacts", comment: "Under Fill from My Card in the menu that fills a form."), font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = Tokens.Symbol.image("person.crop.circle")
            icon.contentTintColor = Tokens.Color.accent
        case .generate:
            name = Label(String(localized: "Use Strong Password", comment: "A row in the fill-password menu on a sign-up form: fill in a password Zigzag makes."), font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
            detail = Label(String(localized: "Saved to your Keychain for \(origin.displayName)", comment: "Under Use Strong Password in the fill-password menu. The placeholder is a site, like github.com."), font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = Tokens.Symbol.image("key.viewfinder")
            icon.contentTintColor = Tokens.Color.accent
        case .systemPasswords:
            name = Label(String(localized: "Passwords…", comment: "A row at the bottom of the fill-password menu: opens the Mac’s own list of passwords to pick one from, as Edit › AutoFill › Passwords… does in other apps."), font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
            detail = Label(String(localized: "From your password apps", comment: "Under Passwords… in the fill-password menu: Apple’s Passwords app, and password manager apps like 1Password or Dashlane."), font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = Tokens.Symbol.image("key")
            icon.contentTintColor = Tokens.Color.accent
        case .note(.privateWindow):
            name = Label(String(localized: "No strong password in a private window", comment: "A dimmed row in the fill-password menu on a sign-up form in a private window, in place of Use Strong Password."), font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
            detail = Label(String(localized: "Private windows don’t save new passwords", comment: "Under the dimmed row saying a private window offers no strong password, in the fill-password menu."), font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            icon.image = Tokens.Symbol.image("key.slash")
            icon.contentTintColor = Tokens.Color.textSecondary
        }
        super.init(frame: .zero)
        if case .note = item { isEnabled = false }
        layer?.cornerRadius = Tokens.Radius.field
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        [icon, name, detail].forEach { addSubview($0) }
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(name.stringValue)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    #if DEBUG
    var debugName: String { name.stringValue }
    #endif

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
