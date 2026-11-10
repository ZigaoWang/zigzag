import AppKit

/// "Save password for github.com?" A calm panel at the top of the page, under the address. The username can be
/// corrected before saving; Never is remembered (and synced) so it never asks there again. It belongs to the tab
/// that signed in: it steps aside while another tab is in front, comes back with that tab, and goes once the tab
/// goes to another site or closes, so it never names the wrong site over someone else's page.
final class SavePasswordPrompt: FloatingPanelView {
    enum Kind {
        case save(username: String)
        case update(Credential)
    }

    private static weak var current: SavePasswordPrompt?

    /// The prompt is on screen in `window`.
    static func isShowing(in window: NSWindow?) -> Bool {
        guard let current, let window else { return false }
        return current.window === window && !current.isHidden
    }

    /// The site's icon, the question and exactly where the password goes: the one header every dialog has.
    private let header = DialogHeader(title: "")
    private let usernameBox = ColorView(color: Tokens.Color.fieldFill)
    private let usernameField = PlainTextField(font: Tokens.Font.body(), placeholder: String(localized: "Username", comment: "Placeholder of the username field in the save-password prompt."))
    private let usernameText = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let isUpdate: Bool
    private let buttons = DialogButtons()
    private let saveButton: PillButton
    private let notNowButton = PillButton(title: String(localized: "Not Now", comment: "Button in the save-password prompt."), style: .plain)
    // The quiet choice, on its own at the left: the two answers on the right are the ones you see.
    private let neverButton = PillButton(title: String(localized: "Never", comment: "Button in the save-password prompt: never offer to save on this site."), style: .quiet)
    private var hideWork: DispatchWorkItem?
    private var finish: (Bool) -> Void = { _ in }
    private var keyMonitor: Any?
    /// The tab that signed in, and the window it's in.
    private weak var tab: Tab?
    private weak var controller: PromptHost?
    /// The site it's about: the tab going anywhere else ends the question.
    private var site = ""
    private var tabsToken: SignalToken?
    private var urlToken: SignalToken?
    private var frameObservers: [Any] = []

    static let width = Tokens.Dialog.width
    private let pad = Tokens.Dialog.padding
    private let fieldHeight = Tokens.Metric.controlHeight + Tokens.Space.x1
    private let buttonHeight = DialogButtons.height

    private init(kind: Kind, origin: Origin) {
        isUpdate = { if case .update = kind { true } else { false } }()
        saveButton = PillButton(title: isUpdate ? String(localized: "Update", comment: "Button in the prompt that offers to update a saved password.") : String(localized: "Save", comment: "Button in the save-password prompt."), style: .prominent)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        radius = Tokens.Radius.panel
        header.title.stringValue = isUpdate ? String(localized: "Update password?", comment: "Title of the prompt that offers to update a saved password.") : String(localized: "Save password?", comment: "Title of the save-password prompt.")
        // Exactly where this password goes, in full.
        header.subtitle.stringValue = origin.displayName
        header.subtitle.toolTip = origin.displayName
        let site = URL(string: "\(origin.scheme)://\(origin.host)")
        if let favicon = site.flatMap({ FaviconStore.shared.cachedIcon(for: $0) }) {
            header.setImage(favicon)
        } else {
            header.setSymbol("key", tint: Brand.Theme.current.accent)
        }
        usernameBox.wantsLayer = true
        usernameBox.layer?.cornerRadius = Tokens.Radius.field
        usernameBox.layer?.cornerCurve = .continuous
        switch kind {
        case .save(let username):
            usernameField.stringValue = username
            usernameBox.addSubview(usernameField)
        case .update(let credential):
            usernameText.stringValue = credential.username.isEmpty ? String(localized: "No username", comment: "Shown in place of a login's username when it has none.") : credential.username
            usernameBox.addSubview(usernameText)
        }
        [header, usernameBox, buttons].forEach { addSubview($0) }
        buttons.leading = [neverButton]
        buttons.trailing = [notNowButton, saveButton]
        neverButton.isHidden = isUpdate
        neverButton.toolTip = String(localized: "Never offer to save on \(origin.displayName)", comment: "Tooltip of the Never button in the save-password prompt. The placeholder is a site, like github.com.")
        frame.size.height = measuredHeight
        onLayout = { [weak self] in self?.layoutContent() }
    }

    private var measuredHeight: CGFloat {
        pad + header.height(for: Self.width - pad * 2) + Tokens.Dialog.gap + fieldHeight + Tokens.Dialog.gap + buttonHeight + pad
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the prompt for a captured login in its tab's window.
    @MainActor static func show(_ kind: Kind, origin: Origin, password: SecretString, in tab: Tab) {
        guard let controller = WindowManager.shared.promptHost(holding: tab) else { return }
        current?.close(saved: false)
        let prompt = SavePasswordPrompt(kind: kind, origin: origin)
        prompt.finish = { saved in
            guard saved else { return }
            Task { @MainActor in
                let store = PasswordStore.shared
                let username = prompt.usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    let done: String
                    switch kind {
                    case .save:
                        try await store.save(origin: origin, username: username, password: password)
                        done = String(localized: "Password saved", comment: "Toast after the save-password prompt saved a password.")
                    case .update(var credential):
                        credential.modified = Date()
                        try await store.update(credential, password: password)
                        done = String(localized: "Password updated", comment: "Toast after the save-password prompt updated a password.")
                    }
                    controller.promptToast(done, symbol: "key", duration: 1.6)
                } catch {
                    controller.promptToast(String(localized: "Couldn’t save the password. Try again from the Passwords window.", comment: "Toast when the save-password prompt couldn't save."), symbol: "exclamationmark.triangle", duration: 3)
                }
            }
        }
        prompt.neverButton.onClick = { [weak prompt] _ in
            Task { await PasswordStore.shared.setNeverSave(true, on: origin) }
            prompt?.close(saved: false)
        }
        prompt.notNowButton.onClick = { [weak prompt] _ in prompt?.close(saved: false) }
        prompt.saveButton.onClick = { [weak prompt] _ in prompt?.close(saved: true) }
        prompt.tab = tab
        prompt.controller = controller
        prompt.site = Self.site(of: origin.host)
        // It slides down from the top edge of its page, like every question a page asks.
        prompt.slidesFromTop = true
        prompt.isHidden = true
        controller.promptOverlay.addSubview(prompt)
        current = prompt
        prompt.followTab()
        prompt.tabsToken = controller.observePromptTabs { [weak prompt] in prompt?.followTab() }
        // The tab went to another site: this was the last site's question.
        prompt.urlToken = tab.changed.observe { [weak prompt, weak tab] change in
            guard change == .url, let prompt, let host = tab?.url?.host(), Self.site(of: host) != prompt.site else { return }
            prompt.close(saved: false)
        }
        // The window resizing, the sidebar coming or going, or the split moving: it stays on its page.
        for card in controller.promptPageViews {
            prompt.frameObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: card, queue: .main) { [weak prompt] _ in
                MainActor.assumeIsolated { prompt?.reposition() }
            })
        }
        // The keyboard stays where you were typing: a prompt that appears mid-sign-in must never catch the rest of
        // a password, or a second Return. Once you click into it, Return saves and Esc says Not Now.
        prompt.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt] event in
            guard let prompt, prompt.superview != nil, !prompt.isHidden, let window = prompt.window, event.window === window else { return event }
            let focused = (window.firstResponder as? NSView).map { $0 === prompt || $0.isDescendant(of: prompt) } ?? false
            // Return that commits a word being composed (Chinese, Japanese) belongs to the field.
            guard focused, !((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false) else { return event }
            switch event.keyCode {
            case 36, 76: prompt.close(saved: true); return nil
            case 53: prompt.close(saved: false); return nil
            default: return event
            }
        }
    }

    /// The site a host belongs to ("github.com" for "gist.github.com"): signing in often hops between its hosts.
    private static func site(of host: String) -> String {
        let host = host.lowercased()
        return PublicSuffix.registrableDomain(host) ?? host
    }

    /// Shown while its tab is in front (either side of a split counts), set aside while another tab is, and gone
    /// once its tab has closed or left the window. It only counts down while it can be seen.
    private func followTab() {
        guard superview != nil, let controller else { return }
        guard let tab, !tab.isClosed, controller.promptHolds(tab) else { close(saved: false); return }
        if controller.promptShows(tab) {
            // The window puts the tab's page in its card as it comes in front, maybe after this: it's placed once
            // the page is there.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.superview != nil, let area = controller.pageFrame(showing: tab) else { return }
                if self.isHidden {
                    self.place(in: area)
                    self.isHidden = false
                    self.present()
                    self.scheduleHide()
                } else {
                    self.reposition()
                }
            }
        } else if !isHidden {
            hideWork?.cancel()
            // Typing that was in it goes back to the page in front.
            if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
                window.makeFirstResponder(controller.promptFrontTab?.webView)
            }
            isHidden = true
        }
    }

    /// At the top of its page, in the middle (over its pane, in a split).
    private func place(in area: NSRect) {
        let width = min(Self.width, area.width - Tokens.Space.x6)
        frame = NSRect(x: round(area.midX - width / 2), y: area.minY + Tokens.Space.x3, width: width, height: measuredHeight)
    }

    /// Back to the top of its page after the page moved. It never jumps: it glides there, except while the window's
    /// edge is being dragged, when it simply stays with the page.
    private func reposition() {
        guard superview != nil, !isHidden, let controller, let tab, let area = controller.pageFrame(showing: tab) else { return }
        let old = frame
        place(in: area)
        let dx = old.minX - frame.minX, dy = old.minY - frame.minY
        guard abs(dx) > 0.5 || abs(dy) > 0.5, !Tokens.Motion.reduceMotion, controller.window?.inLiveResize != true,
              let layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0))
        move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        move.duration = Tokens.Motion.standard
        move.timingFunction = Tokens.Motion.easeInOut
        move.fillMode = .backwards
        layer.add(move, forKey: "follow")
    }

    #if DEBUG
    /// A look at the prompt that saves nothing: every button only closes it.
    static func debugPreview(in controller: BrowserWindowController) {
        guard let origin = Origin(URL(string: "https://powerschool.ykpaoschool.cn")) else { return }
        current?.close(saved: false)
        let prompt = SavePasswordPrompt(kind: .save(username: "student"), origin: origin)
        [prompt.neverButton, prompt.notNowButton, prompt.saveButton].forEach { $0.onClick = { [weak prompt] _ in prompt?.close(saved: false) } }
        let card = controller.root.cardFrame
        prompt.frame.origin = NSPoint(x: card.minX + Tokens.Space.x3, y: card.minY + Tokens.Space.x3)
        controller.root.overlay.addSubview(prompt)
        prompt.present()
        current = prompt
    }

    static func debugClose() { current?.close(saved: false) }

    /// For the debug bridge: Save or Not Now on the prompt showing, as its buttons would.
    /// Says so when there's none yet: it comes up a moment after the sign-in, and an answer sent before then is lost.
    static func debugAnswer(saved: Bool) {
        guard let current, !current.isHidden else { debugLog("minisave: no Save password? showing"); return }
        current.close(saved: saved)
    }

    /// The prompt showing, as its title and site read, and the window it's in.
    static var debugShowing: (text: String, window: NSWindow?)? {
        guard let current, current.superview != nil, !current.isHidden else { return nil }
        return (current.header.title.stringValue + " " + current.header.subtitle.stringValue + " user=" + current.usernameField.stringValue, current.window)
    }
    #endif

    /// Goes away on its own after a while, unless the pointer is on it.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.superview != nil else { return }
                if let window = self.window, self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) || window.firstResponder === self.usernameField.currentEditor() {
                    self.scheduleHide()
                } else {
                    self.close(saved: false)
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func close(saved: Bool) {
        hideWork?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        tabsToken = nil
        urlToken = nil
        frameObservers.forEach { NotificationCenter.default.removeObserver($0) }
        frameObservers = []
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
            window.makeFirstResponder(controller?.promptFrontTab?.webView ?? BrowserWindowController.undoTarget?.selectedWebView)
        }
        if Self.current === self { Self.current = nil }
        let finish = self.finish
        self.finish = { _ in }
        finish(saved)
        // Out of sight already (its tab is behind another): simply gone, with nothing to watch leave.
        if isHidden { removeFromSuperview() } else { dismiss() }
    }

    private func layoutContent() {
        let w = bounds.width, inner = w - pad * 2
        // The site's icon, then what's being asked and where.
        header.frame = NSRect(x: pad, y: pad, width: inner, height: header.height(for: inner))
        // The username, editable before saving.
        usernameBox.frame = NSRect(x: pad, y: header.frame.maxY + Tokens.Dialog.gap, width: inner, height: fieldHeight)
        let fh = ceil(usernameField.intrinsicContentSize.height)
        usernameField.frame = NSRect(x: Tokens.Space.x3, y: (fieldHeight - fh) / 2, width: inner - Tokens.Space.x3 * 2, height: fh)
        usernameText.frame = NSRect(x: Tokens.Space.x3, y: (fieldHeight - usernameText.lineHeight) / 2, width: inner - Tokens.Space.x3 * 2, height: usernameText.lineHeight)
        // Never at the left; Not Now and Save at the right.
        let y = usernameBox.frame.maxY + Tokens.Dialog.gap
        buttons.frame = NSRect(x: pad, y: y, width: inner, height: buttonHeight)
    }
}

extension BrowserWindowController {
    /// Where `tab`'s page is, in the overlay's coordinates: its pane in a split, otherwise the whole page area. Nil
    /// while the tab isn't in front.
    func pageFrame(showing tab: Tab) -> NSRect? {
        guard let webView = tab.webView else { return nil }
        for card in [root.card, root.secondCard] where !card.isHidden && card.alphaValue > 0 && webView.isDescendant(of: card) {
            return root.overlay.convert(card.frame, from: card.superview)
        }
        return nil
    }
}
