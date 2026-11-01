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

    private let icon = FaviconView()
    private let titleLabel = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let siteLabel = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let usernameBox = ColorView(color: Tokens.Color.fieldFill)
    private let usernameField = PlainTextField(font: Tokens.Font.body(), placeholder: "Username")
    private let usernameText = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let isUpdate: Bool
    private let buttons = DialogButtons()
    private let saveButton: PillButton
    private let notNowButton = PillButton(title: "Not Now", style: .plain)
    // The quiet choice, on its own at the left: the two answers on the right are the ones you see.
    private let neverButton = PillButton(title: "Never", style: .quiet)
    private var hideWork: DispatchWorkItem?
    private var finish: (Bool) -> Void = { _ in }
    private var keyMonitor: Any?
    /// The tab that signed in, and the window it's in.
    private weak var tab: Tab?
    private weak var controller: BrowserWindowController?
    /// The site it's about: the tab going anywhere else ends the question.
    private var site = ""
    private var tabsToken: SignalToken?
    private var urlToken: SignalToken?
    private var frameObservers: [Any] = []

    static let width: CGFloat = 320
    private let pad = Tokens.Space.x4
    private let headerHeight: CGFloat = 36
    private let fieldHeight: CGFloat = 36
    private let buttonHeight = DialogButtons.height

    private init(kind: Kind, origin: Origin) {
        isUpdate = { if case .update = kind { true } else { false } }()
        saveButton = PillButton(title: isUpdate ? "Update" : "Save", style: .prominent)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        radius = Tokens.Radius.panel
        titleLabel.stringValue = isUpdate ? "Update password?" : "Save password?"
        // Exactly where this password goes, in full.
        siteLabel.stringValue = origin.displayName
        siteLabel.lineBreakMode = .byTruncatingMiddle
        siteLabel.toolTip = origin.displayName
        let site = URL(string: "\(origin.scheme)://\(origin.host)")
        icon.image = site.flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? Tokens.Symbol.image("key", size: Tokens.Symbol.row)
        usernameBox.wantsLayer = true
        usernameBox.layer?.cornerRadius = Tokens.Radius.field
        usernameBox.layer?.cornerCurve = .continuous
        switch kind {
        case .save(let username):
            usernameField.stringValue = username
            usernameBox.addSubview(usernameField)
        case .update(let credential):
            usernameText.stringValue = credential.username.isEmpty ? "No username" : credential.username
            usernameBox.addSubview(usernameText)
        }
        [icon, titleLabel, siteLabel, usernameBox, buttons].forEach { addSubview($0) }
        buttons.leading = [neverButton]
        buttons.trailing = [notNowButton, saveButton]
        neverButton.isHidden = isUpdate
        neverButton.toolTip = "Never offer to save on \(origin.displayName)"
        frame.size.height = measuredHeight
        onLayout = { [weak self] in self?.layoutContent() }
    }

    private var measuredHeight: CGFloat {
        pad + headerHeight + Tokens.Space.x3 + fieldHeight + Tokens.Space.x3 + buttonHeight + pad
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the prompt for a captured login in its tab's window.
    @MainActor static func show(_ kind: Kind, origin: Origin, password: SecretString, in tab: Tab) {
        guard let controller = WindowManager.shared.controllers.first(where: { $0.tabManager.allTabs.contains { $0 === tab } }) else { return }
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
                        done = "Password saved"
                    case .update(var credential):
                        credential.modified = Date()
                        try await store.update(credential, password: password)
                        done = "Password updated"
                    }
                    Toast.show(done, symbol: "key", duration: 1.6, in: controller)
                } catch {
                    Toast.show("Couldn’t save the password. Try again from the Passwords window", symbol: "exclamationmark.triangle", duration: 3, in: controller)
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
        controller.root.overlay.addSubview(prompt)
        current = prompt
        prompt.followTab()
        prompt.tabsToken = controller.tabManager.changed.observe { [weak prompt] change in
            guard change == .selection || change == .structure || change == .space else { return }
            prompt?.followTab()
        }
        // The tab went to another site: this was the last site's question.
        prompt.urlToken = tab.changed.observe { [weak prompt, weak tab] change in
            guard change == .url, let prompt, let host = tab?.url?.host(), Self.site(of: host) != prompt.site else { return }
            prompt.close(saved: false)
        }
        // The window resizing, the sidebar coming or going, or the split moving: it stays on its page.
        for card in [controller.root.card, controller.root.secondCard] {
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
        let manager = controller.tabManager
        guard let tab, !tab.isClosed, manager.allTabs.contains(where: { $0 === tab }) else { close(saved: false); return }
        let front = manager.selectedTab
        if front === tab || front.map({ manager.partner(of: $0) === tab }) == true {
            // The window puts the tab's page in its card as it comes in front, maybe after this: it's placed once
            // the page is there.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.superview != nil, let area = controller.pageFrame(showing: tab) else { return }
                if self.isHidden {
                    self.place(in: area)
                    self.isHidden = false
                    self.present(always: true)
                    self.scheduleHide()
                } else {
                    self.reposition()
                }
            }
        } else if !isHidden {
            hideWork?.cancel()
            // Typing that was in it goes back to the page in front.
            if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
                window.makeFirstResponder(controller.tabManager.selectedTab?.webView)
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
        move.duration = 0.24
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
        prompt.present(always: true)
        current = prompt
    }

    static func debugClose() { current?.close(saved: false) }
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
            window.makeFirstResponder(BrowserWindowController.undoTarget?.selectedWebView)
        }
        if Self.current === self { Self.current = nil }
        let finish = self.finish
        self.finish = { _ in }
        finish(saved)
        // Out of sight already (its tab is behind another): simply gone, with nothing to watch leave.
        if isHidden { removeFromSuperview() } else { dismiss(always: true) }
    }

    private func layoutContent() {
        let w = bounds.width, inner = w - pad * 2
        // The site's icon, then what's being asked and where.
        let iconSide: CGFloat = 20
        icon.frame = NSRect(x: pad, y: pad + (headerHeight - iconSide) / 2, width: iconSide, height: iconSide)
        let textX = icon.frame.maxX + Tokens.Space.x3
        let block = titleLabel.lineHeight + siteLabel.lineHeight
        titleLabel.frame = NSRect(x: textX, y: pad + (headerHeight - block) / 2, width: w - textX - pad, height: titleLabel.lineHeight)
        siteLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY, width: w - textX - pad, height: siteLabel.lineHeight)
        // The username, editable before saving.
        usernameBox.frame = NSRect(x: pad, y: pad + headerHeight + Tokens.Space.x3, width: inner, height: fieldHeight)
        let fh = ceil(usernameField.intrinsicContentSize.height)
        usernameField.frame = NSRect(x: Tokens.Space.x3, y: (fieldHeight - fh) / 2, width: inner - Tokens.Space.x3 * 2, height: fh)
        usernameText.frame = NSRect(x: Tokens.Space.x3, y: (fieldHeight - usernameText.lineHeight) / 2, width: inner - Tokens.Space.x3 * 2, height: usernameText.lineHeight)
        // Never at the left; Not Now and Save at the right.
        let y = usernameBox.frame.maxY + Tokens.Space.x3
        buttons.frame = NSRect(x: pad, y: y, width: inner, height: buttonHeight)
    }
}

/// A small keycap: on a button, saying which key does the same thing, and in Settings' list of shortcuts.
final class KeyHint: NSView {
    static let height: CGFloat = 20
    private let label: Label
    var onAccent = false { didSet { refresh() } }

    init(_ key: String) {
        label = Label(key, font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        label.alignment = .center
        addSubview(label)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    // Clicks go to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var width: CGFloat { max(Self.height + 4, label.inkWidth + Tokens.Space.x3) }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: Self.height) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - label.lineHeight) / 2, width: bounds.width, height: label.lineHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func refresh() {
        let ink = onAccent ? Brand.Theme.for(self).onAccent : Tokens.Color.textSecondary
        label.textColor = ink
        layer?.backgroundColor = cgColor(onAccent ? ink.withAlphaComponent(0.18) : Tokens.Color.fieldFill)
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
