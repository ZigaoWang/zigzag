import AppKit

/// "Save password for github.com?" A calm panel at the top of the page, under the address. The username can be
/// corrected before saving; Never for This Site is remembered (and synced) so it never asks there again.
final class SavePasswordPrompt: FloatingPanelView {
    enum Kind {
        case save(username: String)
        case update(Credential)
    }

    private static weak var current: SavePasswordPrompt?

    private let badge = ColorView(color: .clear)
    private let badgeIcon = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitle: Label
    private let loginCard = ColorView(color: Tokens.Color.fieldFill)
    private let usernameLabel = Label("Username", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let usernameField = PlainTextField(font: Tokens.Font.body(.medium), placeholder: "Add a username")
    private let usernameText = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let isUpdate: Bool
    private let saveButton: PrimaryButton
    private let notNowButton = TextButton.form("Not Now")
    // The quiet choice: plain text, so the two answers on the right are the ones you see.
    private let neverButton = TextButton(title: "Never for This Site", font: Tokens.Font.body(.medium))
    private let saveKey = KeyHint("↩")
    private let notNowKey = KeyHint("esc")
    private var hideWork: DispatchWorkItem?
    private var finish: (Bool) -> Void = { _ in }
    private var themeToken: SignalToken?
    private var keyMonitor: Any?

    static let width: CGFloat = 420
    private let pad = Tokens.Space.x5

    private init(kind: Kind, origin: Origin) {
        isUpdate = { if case .update = kind { true } else { false } }()
        subtitle = Label(isUpdate ? "Zigzag fills in the new one next time." : "Zigzag fills it in next time, on this site only.",
                         font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
        saveButton = PrimaryButton(title: isUpdate ? "Update" : "Save")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        radius = Tokens.Radius.panel + Tokens.Space.x1
        // The whole site name, wrapping if it's long: you should see exactly where this password goes.
        titleLabel.attributedStringValue = Brand.display((isUpdate ? "Update password for " : "Save password for ") + origin.displayName + "?",
                                                         size: 17, color: Tokens.Color.textPrimary, wraps: true)
        titleLabel.isSelectable = false
        titleLabel.toolTip = origin.displayName
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 12
        badge.layer?.cornerCurve = .continuous
        badgeIcon.image = Tokens.Symbol.image("key.fill", size: 20)
        badge.addSubview(badgeIcon)
        loginCard.wantsLayer = true
        loginCard.layer?.cornerRadius = Tokens.Radius.control + 2
        loginCard.layer?.cornerCurve = .continuous
        loginCard.addSubview(usernameLabel)
        switch kind {
        case .save(let username):
            usernameField.stringValue = username
            loginCard.addSubview(usernameField)
        case .update(let credential):
            usernameText.stringValue = credential.username.isEmpty ? "No username" : credential.username
            loginCard.addSubview(usernameText)
        }
        [badge, titleLabel, subtitle, loginCard, neverButton, notNowButton, saveButton, notNowKey, saveKey].forEach { addSubview($0) }
        neverButton.isHidden = isUpdate
        neverButton.textColor = Tokens.Color.textSecondary
        frame.size.height = measuredHeight
        onLayout = { [weak self] in self?.layoutContent() }
        refreshTheme()
        themeToken = Brand.themeChanged.observe { [weak self] in self?.refreshTheme() }
    }

    private var titleHeight: CGFloat { ceil(titleLabel.sizeThatFits(NSSize(width: Self.width - pad * 2, height: 200)).height) }
    private let badgeSize: CGFloat = 48
    private let cardHeight: CGFloat = 44
    private var measuredHeight: CGFloat {
        pad + badgeSize + Tokens.Space.x4 + titleHeight + Tokens.Space.x1 + subtitle.lineHeight + Tokens.Space.x4 + cardHeight + Tokens.Space.x5 + Tokens.Space.x8 + pad
    }

    /// The key tile takes the space's own color, so the prompt reads as Zigzag's and stands out from the page.
    private func refreshTheme() {
        let accent = Tokens.Color.accent
        badge.color = accent.withAlphaComponent(0.16)
        badgeIcon.contentTintColor = accent
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
                    switch kind {
                    case .save: try await store.save(origin: origin, username: username, password: password)
                    case .update(let credential): try await store.update(credential, password: password)
                    }
                    Toast.show("Password saved", symbol: "key.fill", duration: 1.6, in: controller)
                } catch {
                    Toast.show("Couldn’t save the password. Try again from the Passwords window.", symbol: "exclamationmark.triangle", duration: 3, in: controller)
                }
            }
        }
        prompt.neverButton.onClick = { [weak prompt] _ in
            Task { await PasswordStore.shared.setNeverSave(true, on: origin) }
            prompt?.close(saved: false)
        }
        prompt.notNowButton.onClick = { [weak prompt] _ in prompt?.close(saved: false) }
        prompt.saveButton.onClick = { [weak prompt] _ in prompt?.close(saved: true) }
        let card = controller.root.cardFrame
        prompt.frame.origin = NSPoint(x: card.minX + Tokens.Space.x3, y: card.minY + Tokens.Space.x3)
        controller.root.overlay.addSubview(prompt)
        prompt.needsLayout = true
        prompt.present(always: true)
        Tokens.Motion.slideVertically(prompt, fromOffsetY: -Tokens.Space.x2)
        current = prompt
        prompt.scheduleHide()
        // You just signed in, so the prompt takes the keyboard: Return saves, Esc says Not Now. Clicking the page
        // gives the keyboard back and the keys stop meaning anything here.
        controller.window?.makeFirstResponder(prompt.usernameField)
        if let editor = prompt.usernameField.currentEditor() { editor.selectedRange = NSRange(location: prompt.usernameField.stringValue.count, length: 0) }
        prompt.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt] event in
            guard let prompt, prompt.superview != nil, let window = prompt.window, event.window === window else { return event }
            let focused = (window.firstResponder as? NSView).map { $0 === prompt || $0.isDescendant(of: prompt) } ?? false
            guard focused else { return event }
            switch event.keyCode {
            case 36, 76: prompt.close(saved: true); return nil
            case 53: prompt.close(saved: false); return nil
            default: return event
            }
        }
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
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
            window.makeFirstResponder(BrowserWindowController.undoTarget?.selectedWebView)
        }
        if Self.current === self { Self.current = nil }
        let finish = self.finish
        self.finish = { _ in }
        finish(saved)
        dismiss(always: true)
    }

    private func layoutContent() {
        let w = bounds.width
        badge.frame = NSRect(x: pad, y: pad, width: badgeSize, height: badgeSize)
        badgeIcon.frame = badge.bounds.insetBy(dx: 13, dy: 13)
        titleLabel.frame = NSRect(x: pad, y: badge.frame.maxY + Tokens.Space.x4, width: w - pad * 2, height: titleHeight)
        subtitle.frame = NSRect(x: pad, y: titleLabel.frame.maxY + Tokens.Space.x1, width: w - pad * 2, height: subtitle.lineHeight)
        loginCard.frame = NSRect(x: pad, y: subtitle.frame.maxY + Tokens.Space.x4, width: w - pad * 2, height: cardHeight)
        let inner = Tokens.Space.x3
        let labelWidth: CGFloat = 72
        usernameLabel.frame = NSRect(x: inner, y: (cardHeight - usernameLabel.lineHeight) / 2, width: labelWidth, height: usernameLabel.lineHeight)
        let valueX = inner + labelWidth
        let fh = ceil(usernameField.intrinsicContentSize.height)
        usernameField.frame = NSRect(x: valueX, y: (cardHeight - fh) / 2, width: loginCard.frame.width - valueX - inner, height: fh)
        usernameText.frame = NSRect(x: valueX, y: (cardHeight - usernameText.lineHeight) / 2, width: loginCard.frame.width - valueX - inner, height: usernameText.lineHeight)

        // Each button shows its key, the way it answers: Return saves, Esc is Not Now.
        let y = loginCard.frame.maxY + Tokens.Space.x5
        let h = Tokens.Space.x8
        let hintGap = Tokens.Space.x2
        let saveWidth = saveButton.fittingWidth + saveKey.width + hintGap
        saveButton.frame = NSRect(x: w - pad - saveWidth, y: y, width: saveWidth, height: h)
        saveButton.labelOffset = -(saveKey.width + hintGap) / 2
        saveKey.frame = NSRect(x: saveButton.frame.maxX - Tokens.Space.x3 - saveKey.width, y: y + (h - KeyHint.height) / 2, width: saveKey.width, height: KeyHint.height)
        saveKey.onAccent = true
        let notNowWidth = notNowButton.fittingWidth + notNowKey.width + hintGap
        notNowButton.frame = NSRect(x: saveButton.frame.minX - Tokens.Space.x2 - notNowWidth, y: y, width: notNowWidth, height: h)
        notNowButton.labelOffset = -(notNowKey.width + hintGap) / 2
        notNowKey.frame = NSRect(x: notNowButton.frame.maxX - Tokens.Space.x3 - notNowKey.width, y: y + (h - KeyHint.height) / 2, width: notNowKey.width, height: KeyHint.height)
        neverButton.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: neverButton.fittingWidth, height: h)
    }
}

/// A small keycap on a button, saying which key does the same thing.
final class KeyHint: NSView {
    static let height: CGFloat = 20
    private let label: Label
    var onAccent = false { didSet { refresh() } }

    init(_ key: String) {
        label = Label(key, font: .systemFont(ofSize: 11, weight: .semibold), color: Tokens.Color.textSecondary)
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

    private func refresh() {
        let ink = onAccent ? Brand.Theme.current.onAccent : Tokens.Color.textSecondary
        label.textColor = ink
        layer?.backgroundColor = cgColor(onAccent ? ink.withAlphaComponent(0.18) : Tokens.Color.fieldFill)
    }
}
